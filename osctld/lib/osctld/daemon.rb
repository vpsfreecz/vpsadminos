require 'json'
require 'libosctl'
require 'securerandom'
require 'socket'
require 'osctld/assets/definition'
require 'osctld/exceptions'
require 'osctld/hook'
require 'osctld/hook/base'
require 'osctld/process_identity'
require 'osctld/run_state'
require 'osctld/generic/client_handler'
require 'osctld/upgrade_handoff'

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
      ensure
        @cmd = nil
      end

      def request_stop
        @cmd && @cmd.request_stop
        super
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
        raise 'Daemon already instantiated' if @@instance

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

    # @return [Symbol]
    attr_reader :phase

    private

    # @param config_file [String] path to config file
    def initialize(config_file)
      @config = Config.new(config_file)
      @started_at = Time.now
      @initialized = false
      @stopping = false
      @phase = :starting
      @lifecycle_admission = false
      @state_mutex = Mutex.new
      @state_cv = ConditionVariable.new
      @prepare_mutex = Mutex.new
      @lifecycle_admission_mutex = Mutex.new
      @lifecycle_tasks = {}
      @pre_stop_hooks_ran = false
      @recovery_failures = {}
      @orphans = []
      @drain_blockers = []
      @drain_started_at = nil
      @drain_deadline = nil
      @cleanup_deadline = nil
      @upgrade_handoff = UpgradeHandoff.load
      @autostart_enabled = false
      @autostarts_started = false
      @resume_hooks_complete = false
      @resume_hook_running = false
      @resume_hook_retry = nil
      @readiness_retry_mutex = Mutex.new
      @readiness_retry = nil

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
        @autostart_enabled = KernelParams.autostart_cts?

        # Pool import is inventory-only. Global runtime ownership and recovery
        # have to settle before ordinary autostart is admitted.
        Commands::Pool::Import.run(all: true, autostart: false)

        unless @autostart_enabled
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

      # Reconcile the complete imported inventory before readiness can be
      # published. Individual pool recovery may clear its own failure while a
      # later pool is still being inspected, so @initialized remains false
      # until all global startup barriers have run.
      inventory_runtime_orphans
      persist_upgrade_handoff
      DB::Pools.get.each(&:reconcile_runtime)
      finalize_upgrade_handoff
      @initialized = true
      complete_readiness_safely

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

        @server = Generic::Server.new(
          socket,
          Daemon::ClientHandler,
          thread_group: :management
        )
        @server.start
      end
    end

    def join_server
      @server_thread.join
    end

    # Prepare the daemon for a service restart while keeping all callback and
    # event infrastructure available. The method is idempotent and shared by
    # the management API and signal-driven shutdown.
    #
    # @return [Boolean] true when all lifecycle work is safely settled
    def prepare_stop
      @prepare_mutex.synchronize do
        current_phase = state_sync { @phase }
        return true if current_phase == :prepared
        return false if current_phase == :stopping

        now = Time.now
        lifecycle_admission_sync do
          state_sync do
            @phase = :draining
            @lifecycle_admission = false
            @drain_started_at = now
            @drain_deadline = now + config.restart.drain_timeout
            @cleanup_deadline = nil
            @drain_blockers = []
            @state_cv.broadcast
          end
        end

        log(:info, 'Preparing daemon restart: pausing lifecycle admission')
        pause_autostarts
        unless run_pre_stop_hooks_once
          log(
            :error,
            'Daemon restart preparation aborted because a pre-stop barrier failed'
          )
          abort_prepare_stop
          return false
        end

        if wait_for_lifecycle_drain(config.restart.drain_timeout)
          return true
        end

        blockers = lifecycle_restart_blockers
        log(
          :warn,
          "Lifecycle drain timed out with #{blockers.length} blocker(s), " \
          'terminating only recorded generation processes'
        )
        interrupt_lifecycle_blockers(
          blockers,
          signal: 'TERM',
          kill_generation: false
        )
        cleanup_timeout = config.restart.cleanup_timeout
        term_timeout = cleanup_timeout / 2.0
        kill_timeout = cleanup_timeout - term_timeout
        state_sync do
          @cleanup_deadline = Time.now + cleanup_timeout
          @state_cv.broadcast
        end

        if wait_for_lifecycle_drain(term_timeout)
          return true
        end

        blockers = lifecycle_restart_blockers
        log(
          :warn,
          "Lifecycle termination left #{blockers.length} blocker(s), " \
          'killing exact incomplete generation processes'
        )
        interrupt_lifecycle_blockers(
          blockers,
          signal: 'KILL',
          kill_generation: true
        )

        if wait_for_lifecycle_drain(kill_timeout)
          return true
        end

        blockers = lifecycle_restart_blockers
        state_sync do
          @phase = :drain_failed
          @drain_blockers = public_blockers(blockers)
          @drain_deadline = nil
          @cleanup_deadline = nil
          @state_cv.broadcast
        end
        log(
          :fatal,
          "Daemon restart remains blocked by #{blockers.length} lifecycle " \
          'operation(s); callback services will remain available'
        )
        false
      end
    end

    # Reopen lifecycle admission after a prepared or failed restart attempt.
    # Durable desired-running intents are rescheduled; no queue entry is the
    # sole owner of a requested start.
    def resume
      @prepare_mutex.synchronize do
        current_phase = state_sync { @phase }
        return true if current_phase == :ready
        return false unless %i[draining prepared drain_failed].include?(current_phase)

        state_sync do
          @phase = :blocked
          @lifecycle_admission = false
          @drain_started_at = nil
          @drain_deadline = nil
          @cleanup_deadline = nil
          @drain_blockers = []
          @pre_stop_hooks_ran = false
          @resume_hooks_complete = false
          @state_cv.broadcast
        end

        complete_readiness_safely
        true
      end
    end

    def stop
      unless prepare_stop
        log(:fatal, 'Refusing to stop osctld while lifecycle ownership is unresolved')
        return false
      end

      state_sync do
        @phase = :stopping
        @lifecycle_admission = false
        @stopping = true
        @state_cv.broadcast
      end
      log(:info, 'Stopping daemon after successful lifecycle drain')
      DB::Containers.get.each { |ct| ct.lifecycle.wake_all }
      Container::LifecycleExecutor.wake_all
      @server.stop if @server
      join_server if @server_thread && @server_thread != Thread.current
      FileUtils.rm_f(SOCKET)
      ThreadReaper.drain(group: :management)
      DB::Pools.get.each(&:begin_stop)
      DB::Pools.get.each(&:all_stop)
      UserControl.stop
      # Close and join the send/receive acceptor before the reaper decides that
      # no managed workers remain. Otherwise it can publish one last untracked
      # client handler between ThreadReaper's empty scan and Server#stop.
      SendReceive.stop
      ThreadReaper.stop
      Eventd.shutdown
      DB::Repositories.each(&:stop)
      CpuScheduler.shutdown
      Monitor::Master.stop
      LockRegistry.stop
      log(:info, 'Daemon stopped successfully')
      # Stop can run from a signal helper thread while other background threads
      # are still reacting to shutdown. The graceful cleanup above is complete,
      # so terminate the process without waiting for unmanaged threads.
      exit!(true)
    end

    def stopping?
      state_sync { @stopping }
    end

    def draining?
      state_sync { %i[draining prepared drain_failed].include?(@phase) }
    end

    def ready?
      state_sync { @phase == :ready }
    end

    def lifecycle_admission?
      state_sync { @lifecycle_admission }
    end

    # Reject new lifecycle requests while preserving existing effect workers.
    # Before global readiness, only explicitly tagged internal recovery work
    # may create a lifecycle effect.
    def admit_lifecycle!(internal: false, continuation: false, recovery: false)
      admitted = state_sync do
        @lifecycle_admission \
          || (recovery && %i[starting blocked].include?(@phase)) \
          || (internal && shutdown? && %i[starting blocked].include?(@phase)) \
          || (continuation && %i[draining drain_failed].include?(@phase))
      end
      return true if admitted

      raise CommandFailed, "container lifecycle admission is closed (daemon phase #{phase})"
    end

    # Serialize every operation which can create durable lifecycle ownership
    # with the final restart-barrier check. Callers hold the fence only until
    # the request, lease or worker identity has been persisted.
    def with_lifecycle_admission(**opts)
      lifecycle_admission_sync do
        context = Thread.current[admission_context_key] || {}
        admit_lifecycle!(**context, **opts)
        yield
      end
    end

    # Supply admission semantics to lower-level lease acquisition without
    # holding the global fence across cgroup I/O or other blocking work.
    def with_lifecycle_admission_context(**opts)
      key = admission_context_key
      previous = Thread.current[key]
      Thread.current[key] = (previous || {}).merge(opts)
      yield
    ensure
      Thread.current[key] = previous
    end

    # Register daemon-wide lifecycle work at the admission barrier, then let it
    # run without holding the barrier. The exact worker remains a restart
    # blocker until the operation returns.
    def with_lifecycle_task(kind:, details: {}, **admission)
      identity = ProcessIdentity.capture_thread
      raise CommandFailed, 'unable to identify lifecycle task worker' unless identity

      task_id = SecureRandom.uuid
      with_lifecycle_admission(**admission) do
        state_sync do
          @lifecycle_tasks ||= {}
          @lifecycle_tasks[task_id] = {
            type: 'daemon_lifecycle_task',
            task_id:,
            kind: kind.to_s,
            worker: identity.dump,
            started_at: Time.now.to_f,
            details:
          }
          @state_cv.broadcast
        end
      end

      yield
    ensure
      if task_id
        state_sync do
          @lifecycle_tasks&.delete(task_id)
          @state_cv.broadcast
        end
        lifecycle_state_changed
      end
    end

    def upgrade_handoff_desired?(ct)
      @upgrade_handoff.include?(ct)
    end

    def fulfil_upgrade_handoff(ct)
      @upgrade_handoff.fulfil(ct)
      return unless @upgrade_handoff.empty?

      @upgrade_handoff.complete
      clear_recovery_failure('upgrade-handoff') if @initialized
    end

    def record_recovery_failure(key, message, details = nil)
      state_sync do
        @recovery_failures[key.to_s] = {
          key: key.to_s,
          message:,
          details:,
          recorded_at: Time.now.to_f
        }.compact
        if @initialized && @phase == :ready
          @phase = :blocked
          @lifecycle_admission = false
        end
        @state_cv.broadcast
      end
    end

    def clear_recovery_failure(key)
      state_sync do
        @recovery_failures.delete(key.to_s)
        @state_cv.broadcast
      end
      complete_readiness_safely if @initialized
    end

    def record_orphan(orphan)
      state_sync do
        @orphans << orphan unless @orphans.include?(orphan)
        if @initialized && @phase == :ready
          @phase = :blocked
          @lifecycle_admission = false
        end
        @state_cv.broadcast
      end
    end

    # Re-evaluate startup readiness after a durable lifecycle lease, worker or
    # generation changes. Notifications are coalesced because a single effect
    # commonly commits several adjacent reducer transitions.
    def lifecycle_state_changed
      return unless @initialized
      return unless state_sync { @phase == :blocked }

      mutex = @readiness_retry_mutex ||= Mutex.new
      thread = mutex.synchronize do
        @readiness_retry_dirty = true
        next if @readiness_retry&.alive?

        @readiness_retry = Thread.new do
          loop do
            mutex.synchronize { @readiness_retry_dirty = false }
            Thread.pass
            complete_readiness_safely(schedule_retry: false) \
              unless stopping? || draining?
            readiness_failed = state_sync do
              @recovery_failures.has_key?('daemon-readiness')
            end
            if readiness_failed && !stopping? && !draining?
              sleep(1)
              mutex.synchronize { @readiness_retry_dirty = true }
            end
            repeat = mutex.synchronize do
              if @readiness_retry_dirty
                true
              else
                @readiness_retry = nil
                false
              end
            end
            break unless repeat
          end
        end
      end
      return unless thread

      ThreadReaper.add(thread, nil, group: :durable_lifecycle)
    end

    def status
      containers = DB::Containers.get.map do |ct|
        lifecycle = ct.lifecycle
        snapshot = lifecycle.snapshot
        blockers = lifecycle.daemon_restart_blockers
        active = lifecycle.active_run

        next if active.nil? \
          && lifecycle.desired_state == :stopped \
          && lifecycle.residuals.empty? \
          && blockers.empty?

        {
          pool: ct.pool.name,
          id: ct.id,
          state: ct.state.to_s,
          desired_state: lifecycle.desired_state.to_s,
          intent_id: lifecycle.current_intent_id,
          active_run_id: lifecycle.active_run_id&.to_s,
          active_phase: lifecycle.active_phase&.to_s,
          lifecycle_revision: snapshot['revision'],
          residual_run_ids: lifecycle.residuals.map { |run| Container::RunId.load(run['id']).to_s },
          blockers:
        }
      end.compact

      state_sync do
        {
          schema: 1,
          legacy: false,
          started_at: started_at.to_i,
          initialized:,
          phase: @phase.to_s,
          ready: @phase == :ready,
          lifecycle_admission: @lifecycle_admission,
          drain_started_at: @drain_started_at&.to_f,
          drain_deadline: @drain_deadline&.to_f,
          cleanup_deadline: @cleanup_deadline&.to_f,
          failures: @recovery_failures.values.map(&:dup),
          orphans: @orphans.map(&:dup),
          drain_blockers: @drain_blockers.map(&:dup),
          containers:
        }
      end
    end

    # @return [Boolean]
    def wait_ready(timeout: config.restart.recovery_timeout)
      deadline = monotonic_now + timeout

      state_sync do
        loop do
          return true if @phase == :ready
          return false if %i[drain_failed stopping].include?(@phase)

          remaining = deadline - monotonic_now
          return false if remaining <= 0

          @state_cv.wait(@state_mutex, remaining)
        end
      end
    end

    def user_hook_script_dir
      RunState::DAEMON_HOOK_DIR
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

    protected

    def state_sync(&)
      # Allocated daemon doubles used by focused specs predate initialization.
      # Lazily establish the state lock so diagnostics remain testable without
      # invoking the host-level constructor.
      @state_mutex ||= Mutex.new
      @state_cv ||= ConditionVariable.new
      @state_mutex.synchronize(&)
    end

    def lifecycle_admission_sync(&)
      @lifecycle_admission_mutex ||= Mutex.new
      if @lifecycle_admission_mutex.owned?
        yield
      else
        @lifecycle_admission_mutex.synchronize(&)
      end
    end

    def admission_context_key
      @admission_context_key ||= :"osctld-admission-#{object_id}"
    end

    def complete_readiness(retrying: false)
      became_ready, activation_epoch = lifecycle_admission_sync do
        eligible = state_sync do
          %i[starting blocked ready].include?(@phase) && !@stopping
        end
        next [false, nil] unless eligible

        blockers = lifecycle_restart_blockers
        resume_prerequisites = state_sync do
          @initialized \
            && @recovery_failures.empty? \
            && @orphans.empty?
        end
        if resume_prerequisites && blockers.empty?
          attempt_resume_hooks(retrying:)
        end
        blockers = lifecycle_restart_blockers
        became_ready = state_sync do
          phase_eligible = %i[starting blocked ready].include?(@phase) \
            && !@stopping
          if phase_eligible \
              && @initialized \
              && @resume_hooks_complete \
              && @recovery_failures.empty? \
              && @orphans.empty? \
              && blockers.empty?
            changed = @phase != :ready
            @phase = :ready
            @lifecycle_admission = true
            if changed
              @readiness_epoch = (@readiness_epoch || 0) + 1
            end
          else
            changed = false
            @phase = :blocked if @initialized
            @lifecycle_admission = false
          end
          @state_cv.broadcast
          [changed, @readiness_epoch]
        end
      end

      activate_ready_services(activation_epoch) if became_ready
      became_ready
    end

    # Keep detached readiness retries fail-closed. Readiness now performs
    # hook, inventory and autostart work, so an unexpected exception must not
    # be allowed to terminate the whole daemon through Thread.abort_on_exception.
    def complete_readiness_safely(retrying: false, schedule_retry: true)
      state_sync { @recovery_failures.delete('daemon-readiness') }
      complete_readiness(retrying:)
    rescue StandardError => e
      state_sync do
        @resume_hook_running = false
        unless @stopping
          @phase = :blocked if @initialized
          @lifecycle_admission = false
        end
        @recovery_failures['daemon-readiness'] = {
          key: 'daemon-readiness',
          message: "readiness evaluation failed: #{e.message}",
          details: { exception: e.class.to_s },
          recorded_at: Time.now.to_f
        }
        @state_cv.broadcast
      end
      log(
        :warn,
        "Readiness evaluation failed: #{e.message} (#{e.class})"
      )
      lifecycle_state_changed if schedule_retry && !stopping? && !draining?
      false
    end

    def attempt_resume_hooks(retrying: false)
      claimed = state_sync do
        failures = @recovery_failures.keys
        eligible_failures = if retrying
                              failures == ['daemon-post-resume']
                            else
                              failures.empty?
                            end

        if @initialized \
            && eligible_failures \
            && @orphans.empty? \
            && !@resume_hooks_complete \
            && !@resume_hook_running
          @resume_hook_running = true
          true
        else
          false
        end
      end
      return false unless claimed

      succeeded = run_resume_hooks
      completed = state_sync do
        @resume_hook_running = false
        remaining_failures = @recovery_failures.keys - ['daemon-post-resume']
        if succeeded && remaining_failures.empty? && @orphans.empty?
          @resume_hooks_complete = true
          @recovery_failures.delete('daemon-post-resume')
          @state_cv.broadcast
          true
        else
          false
        end
      end

      unless succeeded
        record_recovery_failure(
          'daemon-post-resume',
          'daemon post-resume hook failed'
        )
        schedule_resume_hook_retry
      end

      completed
    rescue StandardError
      state_sync { @resume_hook_running = false }
      raise
    end

    def activate_ready_services(activation_epoch)
      autostart_action = state_sync do
        if !@autostart_enabled
          :disabled
        elsif @autostarts_started
          :resume
        else
          :start
        end
      end

      activation = proc do |&unpause|
        activate_autostarts(activation_epoch, autostart_action, &unpause)
      end

      case autostart_action
      when :start
        start_autostarts(activation:)
      when :resume
        resume_autostarts(activation:)
      end
      resume_pending_lifecycle_intents
    end

    def activate_autostarts(activation_epoch, action)
      lifecycle_admission_sync do
        eligible = state_sync do
          @phase == :ready \
            && @lifecycle_admission \
            && @readiness_epoch == activation_epoch
        end
        next false unless eligible

        yield
        state_sync { @autostarts_started = true } if action == :start
        true
      end
    end

    def start_autostarts(activation:)
      DB::Pools.get.each do |pool|
        with_lifecycle_task(
          kind: :pool_autostart_activation,
          details: { pool: pool.name }
        ) do
          pool.autostart(
            activation:,
            hook_timeout: restart_hook_timeout
          )
        end
      rescue HookFailed => e
        log(:warn, pool, "Pre-autostart hook failed: #{e.message}")
      rescue CommandFailed => e
        log(:info, pool, "Auto-start activation deferred: #{e.message}")
      end
    end

    def inventory_runtime_orphans
      configured = DB::Containers.get.to_h do |ct|
        [ct.base_cgroup_path, ct]
      end
      runtime_cgroups = CGroup.runtime_container_cgroups
      runtime_by_path = runtime_cgroups.to_h do |runtime|
        [runtime.fetch(:cgroup_path), runtime]
      end

      runtime_cgroups.each do |runtime|
        next if configured.include?(runtime.fetch(:cgroup_path))

        processes = live_runtime_processes(runtime.fetch(:processes))
        next if processes.empty?

        record_orphan({
                        type: 'unconfigured_container_cgroup',
                        cgroup_path: runtime.fetch(:cgroup_path),
                        pids: processes.flat_map { |process| process.fetch(:pids) }.uniq,
                        processes:
                      })
      end

      configured.each_value do |ct|
        runtime = runtime_by_path[ct.base_cgroup_path]
        if runtime
          suspected = runtime.fetch(:processes).reject do |process|
            lifecycle_runtime_process_owned?(ct, process)
          end
          unowned_processes = live_runtime_processes(suspected)
          if unowned_processes.any?
            record_orphan({
                            type: 'configured_container_unowned_processes',
                            pool: ct.pool.name,
                            id: ct.id,
                            state: ct.state.to_s,
                            cgroup_path: ct.base_cgroup_path,
                            pids: unowned_processes.flat_map do |process|
                              process.fetch(:pids)
                            end.uniq,
                            processes: unowned_processes
                          })
            next
          end
        end

        unless %i[running frozen].include?(ct.state)
          next
        end

        active = ct.lifecycle.active_run
        unless active
          record_orphan({
                          type: 'unowned_container_runtime',
                          pool: ct.pool.name,
                          id: ct.id,
                          state: ct.state.to_s,
                          cgroup_path: ct.base_cgroup_path,
                          init_pid: ct.init_pid,
                          reason: 'live container has no lifecycle generation'
                        })
          next
        end
        next unless active.fetch('hazards', []).include?('adopted legacy runtime')

        manager_alive = active.fetch('legacy_managers', []).any? do |config|
          ProcessIdentity.load(config).alive?
        end
        next if manager_alive

        record_orphan({
                        type: 'unowned_container_runtime',
                        pool: ct.pool.name,
                        id: ct.id,
                        state: ct.state.to_s,
                        cgroup_path: ct.base_cgroup_path,
                        init_pid: ct.init_pid,
                        reason: 'adopted legacy manager identity is not alive'
                      })
      end
    end

    # Classify generation runtime by cgroup role. Payload and monitor trees are
    # owned only while LXC/container state says that exact active generation is
    # live. Wrapper and host-effect trees additionally require every PID to
    # match a persisted manager/process identity; merely being below a known
    # generation root is not ownership.
    def lifecycle_runtime_process_owned?(ct, process)
      lifecycle = ct.lifecycle
      return false unless lifecycle.respond_to?(:runtime_generations)

      lifecycle.runtime_generations.any? do |run|
        next false unless %w[active residual].include?(run['role'])

        resources = run.fetch('resources', {})
        root = run.dig('resources', 'cgroup_root')
        next false unless root
        next false unless cgroup_path_within?(root, ct.base_cgroup_path)

        path = process.fetch(:cgroup_path)
        pids = process.fetch(:pids)
        wrapper = resources['wrapper_cgroup']
        host_effects = resources['host_effects']

        if wrapper && cgroup_path_within?(path, wrapper)
          process_pids_owned_by?(pids, generation_manager_identities(run))
        elsif host_effects && cgroup_path_within?(path, host_effects)
          process_pids_owned_by?(pids, generation_process_identities(run))
        elsif lxc_runtime_path?(path, resources)
          lxc_generation_runtime_owned?(ct, run)
        else
          false
        end
      end
    end

    def lxc_runtime_path?(path, resources)
      %w[lxc_payload lxc_monitor lxc_pivot].any? do |name|
        root = resources[name]
        root && cgroup_path_within?(path, root)
      end
    end

    def lxc_generation_runtime_owned?(ct, run)
      return false unless run['role'] == 'active'
      return false unless %w[launching starting running].include?(run['phase'])

      %i[running frozen].include?(ct.state) \
        || (
          run.fetch('kind', 'container') == 'execution' \
          && generation_manager_identities(run).any? do |identity|
            ProcessIdentity.load(identity).alive?
          end
        )
    end

    def generation_manager_identities(run)
      identities = %w[wrapper lxc_start].filter_map { |name| run[name] }
      identities.concat(run.fetch('legacy_managers', []))
    end

    def generation_process_identities(run)
      run.fetch('processes', {}).values.filter_map { |entry| entry['identity'] }
    end

    def process_pids_owned_by?(pids, identities)
      owned = identities.filter_map do |config|
        identity = ProcessIdentity.load(config)
        identity.pid if identity.alive?
      end
      (pids - owned).empty?
    end

    def live_runtime_processes(processes)
      processes.filter_map do |process|
        pids = CGroup.runtime_cgroup_pids(process.fetch(:cgroup_path))
        next if pids.empty?

        process.merge(pids:)
      end
    end

    def cgroup_path_within?(path, root)
      path == root || path.start_with?("#{root}/")
    end

    def runtime_cgroup_restart_blockers
      containers = DB::Containers.get.to_h { |ct| [ct.base_cgroup_path, ct] }

      CGroup.runtime_container_cgroups.filter_map do |runtime|
        ct = containers[runtime.fetch(:cgroup_path)]
        next unless ct

        suspected = runtime.fetch(:processes).reject do |process|
          lifecycle_runtime_process_owned?(ct, process)
        end
        processes = live_runtime_processes(suspected)
        next if processes.empty?

        [
          ct,
          {
            type: 'unowned_container_cgroup_processes',
            phase: ct.state.to_s,
            processes:
          }
        ]
      end
    rescue StandardError => e
      [
        [
          nil,
          {
            type: 'runtime_cgroup_inventory_error',
            error: e.message,
            error_class: e.class.name
          }
        ]
      ]
    end

    # Persist every boot-bound legacy start intent only after all pools have
    # been imported. This includes a container which became stopped while the
    # old daemon was draining: it must be represented by a durable
    # desired-running intent before the handoff file can be removed.
    def persist_upgrade_handoff
      @upgrade_handoff.remaining.each do |pool, id|
        ct = DB::Containers.find(id, pool)
        next unless ct

        with_lifecycle_admission(internal: true, recovery: true) do
          ct.lifecycle.persist_running_intent(
            source: 'legacy-runtime-upgrade'
          )
        end
        if ct.lifecycle.desired_state == :running
          fulfil_upgrade_handoff(ct)
        else
          log(
            :warn,
            ct,
            'Unable to persist legacy runtime start intent'
          )
        end
      end
    end

    def finalize_upgrade_handoff
      remaining = @upgrade_handoff.remaining
      if remaining.empty?
        @upgrade_handoff.complete
      else
        record_recovery_failure(
          'upgrade-handoff',
          'not all legacy runtime start intents could be persisted',
          containers: remaining.map { |pool, id| { pool:, id: } }
        )
      end
    end

    def finish_prepare_stop
      state_sync do
        @phase = :prepared
        @drain_blockers = []
        @drain_deadline = nil
        @cleanup_deadline = nil
        @state_cv.broadcast
      end
      log(:info, 'Container lifecycle drain completed')
      true
    end

    def abort_prepare_stop
      state_sync do
        @phase = :blocked
        @lifecycle_admission = false
        @drain_started_at = nil
        @drain_deadline = nil
        @cleanup_deadline = nil
        @drain_blockers = []
        @pre_stop_hooks_ran = false
        @resume_hooks_complete = false
        @state_cv.broadcast
      end
      complete_readiness_safely
    end

    def pause_autostarts
      DB::Pools.get.each do |pool|
        pool.pause_autostart if pool.respond_to?(:pause_autostart)
      end
    end

    def resume_autostarts(activation:)
      DB::Pools.get.each do |pool|
        pool.resume_autostart(activation:) if pool.respond_to?(:resume_autostart)
      end
    end

    def resume_pending_lifecycle_intents
      DB::Containers.get.each do |ct|
        lifecycle = ct.lifecycle
        next unless lifecycle.desired_state == :running
        next if lifecycle.active_phase == :running && ct.running?
        next if lifecycle.autostart_intent?

        intent_id = lifecycle.current_intent_id
        thread = Thread.new do
          ret = Commands::Container::Start.run(
            pool: ct.pool.name,
            id: ct.id,
            lifecycle_source: 'daemon-resume',
            lifecycle_intent_id: intent_id,
            manipulation_lock: 'wait'
          )
          unless ret[:status]
            log(
              :info,
              ct,
              "Deferred desired-running intent was not started: #{ret[:message]}"
            )
          end
        rescue CommandFailed => e
          log(:info, ct, "Desired-running intent deferred: #{e.message}")
        rescue StandardError => e
          log(
            :warn,
            ct,
            "Unable to resume desired-running intent: #{e.message} (#{e.class})"
          )
        end
        ThreadReaper.add(thread, nil, group: :durable_lifecycle)
      end
    end

    def wait_for_lifecycle_drain(timeout)
      deadline = monotonic_now + timeout

      loop do
        blockers = lifecycle_restart_blockers
        state_sync do
          @drain_blockers = public_blockers(blockers)
          @state_cv.broadcast
        end
        if blockers.empty?
          prepared = lifecycle_admission_sync do
            next false unless lifecycle_restart_blockers.empty?

            finish_prepare_stop
          end
          return true if prepared
        end
        return false if monotonic_now >= deadline

        sleep([0.2, deadline - monotonic_now].min)
      end
    end

    def lifecycle_restart_blockers
      tasks = state_sync do
        (@lifecycle_tasks || {}).values.filter_map do |task|
          worker = ProcessIdentity.load(task.fetch(:worker))
          next unless worker.alive?

          [nil, task.dup]
        end
      end

      container_blockers = DB::Containers.get.flat_map do |ct|
        ct.lifecycle.daemon_restart_blockers.map { |blocker| [ct, blocker] }
      end
      tasks + container_blockers + runtime_cgroup_restart_blockers
    end

    def public_blockers(blockers)
      blockers.map do |ct, blocker|
        ct ? blocker.merge(pool: ct.pool.name, id: ct.id) : blocker
      end
    end

    def interrupt_lifecycle_blockers(blockers, signal:, kill_generation:)
      blockers.each do |ct, blocker|
        next unless ct
        next unless blocker[:type] == 'container_generation'

        run_id = blocker[:run_id]
        next unless run_id

        if blocker[:phase] == 'preparing' && blocker[:effect].nil?
          ct.lifecycle.cancel_unlaunched(
            run_id,
            'unlaunched start deferred across daemon restart'
          )
          next
        end

        ct.lifecycle.daemon_restart_processes(run_id).each do |cfg|
          identity = ProcessIdentity.load(cfg)
          next unless identity.alive?
          next if identity.pid == Process.pid

          log(
            :warn,
            ct,
            "Sending #{signal} to lifecycle process #{identity.pid} for #{run_id}"
          )
          Process.kill(signal, identity.pid) if identity.alive?
        rescue Errno::ESRCH
          next
        end

        # Before RUNNING, every payload belongs to an incomplete generation.
        # Killing that exact cgroup is safe and lets its worker/finalizer settle.
        next unless kill_generation
        next if blocker[:phase] == 'running'

        Container::Recovery.new(ct).kill_generation(run_id)
      rescue StandardError => e
        log(:warn, ct, "Unable to interrupt lifecycle blocker: #{e.message} (#{e.class})")
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def run_pre_stop_hooks_once
      return true if state_sync { @pre_stop_hooks_ran }
      return false unless run_pre_stop_hooks

      state_sync { @pre_stop_hooks_ran = true }
      true
    end

    def run_pre_stop_hooks
      Hook.run(self, :pre_stop, timeout: restart_hook_timeout)
      true
    rescue HookFailed => e
      log(:error, "Daemon pre-stop hook failed: #{e.message}")
      false
    end

    def run_resume_hooks
      Hook.run(self, :post_resume, timeout: restart_hook_timeout)
      true
    rescue HookFailed => e
      log(:warn, "Daemon post-resume hook failed: #{e.message}")
      false
    end

    def restart_hook_timeout
      restart = config&.restart
      return 30 unless restart

      restart.respond_to?(:hook_timeout) ? restart.hook_timeout : 30
    end

    def schedule_resume_hook_retry
      return if @resume_hook_retry&.alive?

      @resume_hook_retry = Thread.new do
        loop do
          sleep(1)
          break if stopping? || draining?
          next unless state_sync do
            @initialized \
              && @recovery_failures.keys == ['daemon-post-resume'] \
              && @orphans.empty?
          end
          break if complete_readiness_safely(retrying: true)
        end
      end
      ThreadReaper.add(@resume_hook_retry, nil, group: :durable_lifecycle)
    end

    module Hooks
      class PreStop < Hook::Base
        hook(OsCtld::Daemon, :pre_stop, self)
        blocking true

        protected

        def environment
          super.merge({
                        'OSCTL_DAEMON_STATE' => 'stopping',
                        'OSCTL_DAEMON_PID' => Process.pid.to_s
                      })
        end
      end

      class PostResume < Hook::Base
        hook(OsCtld::Daemon, :post_resume, self)
        blocking true

        protected

        def environment
          super.merge({
                        'OSCTL_DAEMON_STATE' => 'running',
                        'OSCTL_DAEMON_PID' => Process.pid.to_s
                      })
        end
      end
    end
  end
end
