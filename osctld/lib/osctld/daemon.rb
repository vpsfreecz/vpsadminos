require 'socket'

module OsCtld
  class Daemon
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    SOCKET = File.join(RunState::RUNDIR, 'osctld.sock')

    class ClientHandler < Generic::ClientHandler
      def handle_cmd(req)
        cmd = Command.find(req[:cmd].to_sym)
        error!("Unsupported command '#{req[:cmd]}'") unless cmd

        cmd.run(req[:opts], self)
      end

      def server_version
        OsCtld::VERSION
      end

      def log_type
        self.class.name
      end
    end

    def initialize
      Thread.abort_on_exception = true
      DB::Users.instance
      DB::Groups.instance
      DB::Containers.instance
      Console.init
    end

    def setup
      # Setup /run/osctl
      RunState.create

      # Increase alloed number of open files
      syscmd("prlimit --nofile=4096 --pid #{Process.pid}")

      # Load data pools
      Commands::Pool::Import.run(all: true)

      # Start accepting client commands
      serve
    end

    def serve
      log(:info, "Listening on control socket at #{SOCKET}")

      socket = UNIXServer.new(SOCKET)
      File.chmod(0600, SOCKET)

      @server = Generic::Server.new(socket, Daemon::ClientHandler)
      @server.start
    end

    def stop
      log(:info, 'Exiting')
      @server.stop if @server
      File.unlink(SOCKET) if File.exist?(SOCKET)
      UserControl.stop
      Monitor::Master.stop
      exit(false)
    end

    def log_type
      'daemon'
    end
  end
end
