require 'libosctl'
require 'socket'
require 'thread'
require 'osctld/assets/definition'
require 'osctld/run_state'
require 'osctld/generic/client_handler'

module OsCtld
  class Daemon
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Assets::Definition

    SOCKET = File.join(RunState::RUNDIR, 'osctld.sock')

    class ClientHandler < Generic::ClientHandler
      def handle_cmd(req)
        cmd_class = Command.find(req[:cmd].to_sym)
        error!("Unsupported command '#{req[:cmd]}'") unless cmd_class

        id = Command.get_id
        Eventd.report(:management, id: id, state: :run, cmd: req[:cmd], opts: req[:opts])

        @cmd = cmd = cmd_class.new(req[:opts], id: id, handler: self)
        ret = cmd.base_execute

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

      def request_stop
        @cmd && @cmd.request_stop
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
      ThreadReaper.start
      Console.init
      Eventd.start
      History.start
      Devices::Lock.instance
      LockRegistry.start
      UGidRegistry.instance
      SystemUsers.instance

      at_exit do
        if $!.is_a?(DeadlockDetected)
          log(:fatal, 'Possible deadlock detected')
          LockRegistry.dump
        end
      end
    end

    public
    def setup
      # Setup /run/osctl
      RunState.create

      SystemLimits.instance

      # Increase allowed number of open files
      PrLimits.set(Process.pid, PrLimits::NOFILE, 16384, 16384)

      # Setup shared AppArmor files
      AppArmor.setup

      # Migration hooks and server
      Migration.setup

      # Setup network interfaces
      NetInterface.setup

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
      log(:info, 'Shutting down')
      Eventd.stop
      @server.stop if @server
      File.unlink(SOCKET) if File.exist?(SOCKET)
      UserControl.stop
      Migration.stop
      DB::Pools.get.each { |pool| pool.stop }
      ThreadReaper.stop
      Monitor::Master.stop
      LockRegistry.stop
      log(:info, 'Shutdown successful')
      exit(false)
    end

    def log_type
      'daemon'
    end
  end
end
