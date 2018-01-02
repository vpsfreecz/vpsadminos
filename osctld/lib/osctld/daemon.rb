require 'socket'

module OsCtld
  class Daemon
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    SOCKET = File.join(RunState::RUNDIR, 'osctld.sock')

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
      log(:info, :init, "Listening on control socket at #{SOCKET}")

      @srv = UNIXServer.new(SOCKET)
      File.chmod(0600, SOCKET)

      loop do
        begin
          c = @srv.accept

        rescue IOError
          return

        else
          handle_client(c)
        end
      end
    end

    def stop
      log(:info, :daemon, "Exiting")
      @srv.close if @srv
      File.unlink(SOCKET) if File.exist?(SOCKET)
      UserControl.stop
      Monitor::Master.stop
      exit(false)
    end

    private
    def handle_client(client)
      log(:info, :server, 'Received a new client connection')

      Thread.new do
        c = ClientHandler.new(client)
        c.communicate
      end
    end
  end
end
