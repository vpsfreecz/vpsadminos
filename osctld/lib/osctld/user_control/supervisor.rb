require 'libosctl'
require 'osctld/generic/client_handler'
require 'osctld/process_identity'

module OsCtld
  class UserControl::Supervisor
    DIRECT_COMMANDS = %w[
      ct_netns_setup
      ct_on_start
      ct_post_stop
      ct_pre_start
      ct_wrapper_start
      veth_down
      veth_up
    ].freeze

    NAMESPACED_COMMANDS = %w[
      ct_autodev
      ct_post_mount
      ct_pre_mount
    ].freeze

    module AuthenticatedHandler
      protected

      def validate_request(req, allowed_commands)
        return error('invalid input') unless req.is_a?(Hash) && req[:opts].is_a?(Hash)
        return error('invalid cmd') unless allowed_commands.include?(req[:cmd].to_s)

        nil
      end

      def with_peer(namespaces: [], root: false)
        peer = nil

        begin
          cred = @sock.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED)
          pid, uid, gid = cred.unpack('LLL')
          peer = ProcessIdentity.new(pid, namespaces:, root:)
        rescue SystemCallError, IOError, ArgumentError
          return error('unable to authenticate peer')
        end

        begin
          yield(peer, uid, gid)
        ensure
          peer.close
        end
      end

      def run_command(req, user, peer)
        cmd = UserControl::Command.find(req[:cmd].to_sym)
        return error("Unsupported command '#{req[:cmd]}'") unless cmd

        cmd.run(user, req[:opts].dup, peer:)
      end
    end

    class ClientHandler < Generic::ClientHandler
      include AuthenticatedHandler

      def handle_cmd(req)
        ret = validate_request(req, DIRECT_COMMANDS)
        return ret if ret

        with_peer do |peer, uid, gid|
          user = opts[:user]

          unless uid == user.ugid && gid == user.ugid
            log(:warn, "Invalid direct peer pid=#{peer.pid},uid=#{uid},gid=#{gid} for user #{user.ident}")
            next error('invalid user')
          end

          run_command(req, user, peer)
        end
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
      include AuthenticatedHandler

      ROOTFS_DESCRIPTOR_TIMEOUT = 5
      ROOTFS_DESCRIPTOR_REQUEST = 'send-rootfs-mount-fd'.freeze

      def handle_cmd(req)
        ret = validate_request(req, NAMESPACED_COMMANDS)
        return ret if ret

        ct = DB::Containers.find(req[:opts][:id], req[:opts][:pool])
        return error('invalid container') unless ct

        with_peer(namespaces: %i[mnt user], root: true) do |peer, uid, gid|
          user = ct.user

          unless peer.in_cgroup_subtree?(ct.base_cgroup_path)
            log(:warn, "Namespaced peer pid=#{peer.pid} does not belong to #{ct.ident}")
            next error('invalid container')
          end

          expected_uid = user.uid_map.ns_to_host(0)
          expected_gid = user.gid_map.ns_to_host(0)

          unless uid == expected_uid && gid == expected_gid
            log(
              :warn,
              "Invalid namespaced peer pid=#{peer.pid},uid=#{uid},gid=#{gid} " \
              "for #{ct.ident}, expected uid=#{expected_uid},gid=#{expected_gid}"
            )
            next error('invalid user')
          end

          rootfs_dir = nil

          begin
            if req[:cmd].to_s == 'ct_post_mount'
              send_update(ROOTFS_DESCRIPTOR_REQUEST)

              unless @sock.wait_readable(ROOTFS_DESCRIPTOR_TIMEOUT)
                next error('missing mounted container rootfs descriptor')
              end

              rootfs_dir = @sock.recv_io
              req[:opts][:rootfs_dir] = rootfs_dir
            end

            log(:info, "Forwarding request to user #{user.ident}")
            run_command(req, user, peer)
          rescue SystemCallError, IOError, ArgumentError, TypeError
            error('invalid mounted container rootfs descriptor')
          ensure
            rootfs_dir&.close unless rootfs_dir&.closed?
          end
        end
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

        s = Generic::Server.new(
          socket,
          ClientHandler,
          opts: {
            user:
          },
          thread_group: :user_control
        )
        t = Thread.new { s.start }

        @servers[server_key(user)] = [s, t]
      end
    end

    def stop_server(user)
      sync do
        s, t = @servers[server_key(user)]
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

        s = Generic::Server.new(
          socket,
          NamespacedClientHandler,
          thread_group: :user_control
        )
        t = Thread.new { s.start }

        @servers[:namespaced] = [s, t]
      end
    end

    def stop_all
      sync do
        @servers.each_value { |st| st[0].stop }
        @servers.each_value { |st| st[1].join }
      end
    end

    private

    def sync(&)
      @mutex.synchronize(&)
    end

    def socket_path(user)
      File.join(RunState::USER_CONTROL_DIR, "#{user.ugid}.sock")
    end

    def server_key(user)
      user.ident
    end
  end
end
