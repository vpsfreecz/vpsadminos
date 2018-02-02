require 'thread'

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

    @@instance = nil

    def self.instance
      @@instance = new unless @@instance
      @@instance
    end

    class << self
      %i(start_server stop_server stop_all).each do |v|
        define_method(v) do |*args, &block|
          instance.send(v, *args, &block)
        end
      end
    end

    private
    def initialize
      @mutex = Mutex.new
      @servers = {}
    end

    public
    def start_server(user)
      sync do
        path = socket_path(user)
        socket = UNIXServer.new(path)

        File.chown(0, user.ugid, path)
        File.chmod(0660, path)

        s = Generic::Server.new(socket, ClientHandler, opts: {
          user: user,
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

    def stop_all
      sync do
        @servers.each { |user, st| st[0].stop }
        @servers.each { |user, st| st[1].join }
      end
    end

    private
    def sync
      @mutex.synchronize { yield }
    end

    def socket_path(user)
      File.join(RunState::USER_CONTROL_DIR, "#{user.ugid}.sock")
    end
  end
end
