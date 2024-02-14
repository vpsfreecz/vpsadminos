require 'libosctl'
require 'osctld/generic/client_handler'

module OsCtld
  class UserControl::Supervisor
    class ClientHandler < Generic::ClientHandler
      def handle_cmd(req)
        cmd = UserControl::Command.find(req[:cmd].to_sym)
        error!("Unsupported command '#{req[:cmd]}'") unless cmd

        cmd.run(opts[:user], req[:opts])
      end

      def log_type
        self.class.name
      end
    end

    # Client handler for commands called from a container's user namespace.
    #
    # The handler finds appropriate osctld user and passes control to standard
    # client handler.
    class NamespacedClientHandler < Generic::ClientHandler
      def handle_cmd(req)
        return error('invalid input') unless req.is_a?(Hash)

        # For now, allow only ct_autodev
        unless %w[ct_autodev ct_pre_mount ct_post_mount].include?(req[:cmd])
          return error('invalid cmd')
        end

        # Find out which user has connected
        cred = @sock.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED)
        pid, uid, gid = cred.unpack('LLL')

        # Locate the user in DB using the uid of the caller process' grandparent:
        # - caller: lxc hook
        # - parent: lxc-start, future /sbin/init
        # - grandparent: lxc-start running within the host namespace
        process = OsCtl::Lib::OsProcess.new(pid)
        gpuid = process.grandparent.ruid

        user = DB::Users.get.detect do |u|
          u.pool.name == req[:opts][:pool] && u.ugid == gpuid
        end

        unless user
          log(:warn, "Unable to find user for pid=#{pid},uid=#{uid},gid=#{gid}")
          return error('invalid user')
        end

        # Just to be sure that we have the right user, compare the caller's
        # uid/gid with the user's uid/gid within user namespace.
        {
          uid: [user.uid_map.ns_to_host(0), uid],
          gid: [user.gid_map.ns_to_host(0), gid]
        }.each do |type, ids|
          expected, got = ids

          next unless expected != got

          log(:warn, "Caller's #{type} does not match the located user: " +
                     "user=#{user.ident}, expected #{type}=#{expected}, " +
                     "got #{type}=#{got}")
          return error('invalid user')
        end

        req[:opts].update(client_pid: pid) if req[:opts].is_a?(Hash)

        # Forward to a real client handler
        log(:info, "Forwarding request to user #{user.ident}")
        handler = ClientHandler.new(@sock, user:)
        handler.handle_cmd(req)
      end

      def log_type
        self.class.name
      end
    end

    @@instance = nil

    def self.instance
      @@instance ||= new
      @@instance
    end

    class << self
      %i[start_server stop_server stop_all].each do |v|
        define_method(v) do |*args, &block|
          instance.send(v, *args, &block)
        end
      end
    end

    private

    def initialize
      @mutex = Mutex.new
      @servers = {}

      start_namespaced
    end

    public

    def start_server(user)
      sync do
        path = socket_path(user)
        socket = UNIXServer.new(path)

        File.chown(0, user.ugid, path)
        File.chmod(0o660, path)

        s = Generic::Server.new(socket, ClientHandler, opts: {
          user:
        })
        t = Thread.new { s.start }

        @servers[user.name] = [s, t]
      end
    end

    def stop_server(user)
      sync do
        s, t = @servers[user.name]
        s.stop
        t.join
        File.unlink(socket_path(user))
      end
    end

    def start_namespaced
      sync do
        path = File.join(RunState::USER_CONTROL_DIR, 'namespaced.sock')
        socket = UNIXServer.new(path)

        File.chown(0, 0, path)
        File.chmod(0o666, path)

        s = Generic::Server.new(socket, NamespacedClientHandler)
        t = Thread.new { s.start }

        @servers[:namespaced] = [s, t]
      end
    end

    def stop_all
      sync do
        @servers.each { |_user, st| st[0].stop }
        @servers.each { |_user, st| st[1].join }
      end

      s, t = @servers[:namespaced]
      s.stop
      t.join
    end

    private

    def sync(&)
      @mutex.synchronize(&)
    end

    def socket_path(user)
      File.join(RunState::USER_CONTROL_DIR, "#{user.ugid}.sock")
    end
  end
end
