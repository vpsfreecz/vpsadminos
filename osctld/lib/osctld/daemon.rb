require 'json'
require 'libosctl'
require 'socket'
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
        Eventd.report(:management, id:, state: :run, cmd: req[:cmd], opts: req[:opts])

        @cmd = cmd = cmd_class.new(req[:opts], id:, handler: self)
        ret = cmd.base_execute

        if ret.is_a?(Hash) && ret[:status]
          Eventd.report(:management, id:, state: :done, cmd: req[:cmd], opts: req[:opts])

        else
          Eventd.report(:management, id:, state: :failed, cmd: req[:cmd], opts: req[:opts])
        end

        ret
      rescue StandardError => e
        Eventd.report(:management, id:, state: :failed, cmd: req[:cmd], opts: req[:opts])
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
      # @param config [String] path to config file
      def create(config)
        raise 'Daemon already instantiated' if @instance

        @@instance = new(config)
      end

      def get
        @@instance
      end
    end

    # @return [Config]
    attr_reader :config

    # @return [Time]
    attr_reader :started_at

    # @return [Boolean]
    attr_reader :initialized

    private

    # @param config_file [String] path to config file
    def initialize(config_file)
      @config = Config.new(config_file)
      @started_at = Time.now
      @initialized = false
      @stopping = false

      Thread.abort_on_exception = true
      CGroup.init
      DB::Users.instance
      DB::Groups.instance
      DB::Containers.instance
      ThreadReaper.start
      Console.init
      Eventd.start
      History.start
      Devices::Lock.instance
      LockRegistry.setup(config.enable_lock_registry?)
      UGidRegistry.instance
      SystemUsers.instance
      ErbTemplateCache.instance

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

      # Open start config
      start_cfg = RunState.open_start_config

      SystemLimits.instance

      CpuScheduler.setup

      # Increase allowed number of open files
      PrLimits.set(Process.pid, PrLimits::NOFILE, 131_072, 131_072)

      # Setup shared AppArmor files
      if AppArmor.enabled?
        log(:info, 'AppArmor enabled')
        AppArmor.setup
      else
        log(:info, 'AppArmor disabled')
      end

      # Setup BPF FS
      BpfFs.setup

      # User-control supervisor
      UserControl::Supervisor.instance

      # Send/Receive hooks and server
      SendReceive.setup

      # Setup network interfaces
      NetInterface.setup

      # Start accepting client commands
      serve

      # Load data pools
      if KernelParams.import_pools?
        autostart = KernelParams.autostart_cts?

        Commands::Pool::Import.run(all: true, autostart:)

        unless autostart
          log(:info, 'Container autostart disabled by kernel parameter')
        end
      else
        log(:info, 'Pool autoimport disabled by kernel parameter')
      end

      # Resume shutdown
      if shutdown?
        log(:info, 'Resuming shutdown')
        Commands::Self::Shutdown.run
      end

      # Close start config
      start_cfg.close

      # All components are up
      @initialized = true

      # Wait for the server to finish
      join_server
    end

    def assets
      define_assets do |add|
        RunState.assets(add)

        add.socket(
          SOCKET,
          desc: 'Management socket',
          user: 0,
          group: 0,
          mode: 0o600
        )

        Devices::V2::BpfProgramCache.assets(add)
      end
    end

    def serve
      @server_thread = Thread.new do
        log(:info, "Listening on control socket at #{SOCKET}")

        socket = UNIXServer.new(SOCKET)
        File.chmod(0o600, SOCKET)

        @server = Generic::Server.new(socket, Daemon::ClientHandler)
        @server.start
      end
    end

    def join_server
      @server_thread.join
    end

    def stop
      @stopping = true
      log(:info, 'Stopping daemon')
      Eventd.shutdown
      @server.stop if @server
      FileUtils.rm_f(SOCKET)
      UserControl.stop
      SendReceive.stop
      DB::Pools.get.each(&:stop)
      CpuScheduler.shutdown
      ThreadReaper.stop
      Monitor::Master.stop
      LockRegistry.stop
      log(:info, 'Daemon stopped successfully')
      exit(false)
    end

    def stopping?
      @stopping
    end

    def begin_shutdown
      @abort_shutdown = false
      File.new(RunState::SHUTDOWN_MARKER, 'w', 0o000).close
    end

    def abort_shutdown
      @abort_shutdown = true

      begin
        File.unlink(RunState::SHUTDOWN_MARKER)
      rescue Errno::ENOENT
        # ignore
      end
    end

    def confirm_shutdown
      unless File.exist?(RunState::SHUTDOWN_MARKER)
        File.new(RunState::SHUTDOWN_MARKER, 'w', 0o100).close
      end

      File.chmod(0o100, RunState::SHUTDOWN_MARKER)
    end

    def shutdown?
      File.exist?(RunState::SHUTDOWN_MARKER)
    end

    def abort_shutdown?
      @abort_shutdown
    end

    def log_type
      'daemon'
    end
  end
end
