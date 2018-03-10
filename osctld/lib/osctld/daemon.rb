require 'socket'

module OsCtld
  class Daemon
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Assets::Definition

    SOCKET = File.join(RunState::RUNDIR, 'osctld.sock')

    class ClientHandler < Generic::ClientHandler
      def handle_cmd(req)
        cmd = Command.find(req[:cmd].to_sym)
        error!("Unsupported command '#{req[:cmd]}'") unless cmd

        id = Command.get_id
        Eventd.report(:management, id: id, state: :run, cmd: req[:cmd], opts: req[:opts])

        ret = cmd.run(req[:opts], id: id, handler: self)

        if ret.is_a?(Hash) && ret[:status]
          Eventd.report(:management, id: id, state: :done, cmd: req[:cmd], opts: req[:opts])

        else
          Eventd.report(:management, id: id, state: :failed, cmd: req[:cmd], opts: req[:opts])
        end

        ret

      rescue => err
        Eventd.report(:management, id: id, state: :failed, cmd: req[:cmd], opts: req[:opts])
        raise
      end

      def server_version
        OsCtld::VERSION
      end

      def log_type
        self.class.name
      end
    end

    @@instance = nil

    class << self
      def get
        @@instance ||= new
      end
    end

    private
    def initialize
      Thread.abort_on_exception = true
      DB::Users.instance
      DB::Groups.instance
      DB::Containers.instance
      Console.init
      Eventd.start
      History.start
    end

    public
    def setup
      # Setup /run/osctl
      RunState.create

      # Increase alloed number of open files
      syscmd("prlimit --nofile=4096 --pid #{Process.pid}")

      # Migration hooks and server
      Migration.setup

      # Load data pools
      Commands::Pool::Import.run(all: true, autostart: true)

      # Start accepting client commands
      serve
    end

    def assets
      define_assets do |add|
        RunState.assets(add)

        add.socket(
          SOCKET,
          desc: 'Management socket',
          user: 0,
          group: 0,
          mode: 0600
        )
      end
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
      Eventd.stop
      @server.stop if @server
      File.unlink(SOCKET) if File.exist?(SOCKET)
      UserControl.stop
      Migration.stop
      DB::Pools.get.each { |pool| pool.stop }
      Monitor::Master.stop
      exit(false)
    end

    def log_type
      'daemon'
    end
  end
end
