# frozen_string_literal: true

require 'osctld/daemon'
require 'osctld/command'
require 'osctld/container/lifecycle'
require 'osctld/eventd'
require 'osctld/thread_reaper'

RSpec.describe OsCtld::Daemon do
  before do
    described_class.class_variable_set(:@@instance, nil)
    allow(OsCtld::CGroup).to receive(:runtime_container_cgroups).and_return([])
  end

  after do
    described_class.class_variable_set(:@@instance, nil)
  end

  describe '.create' do
    it 'rejects duplicate creation and keeps the original instance' do
      daemon = instance_double(described_class)

      allow(described_class).to receive(:new).with('daemon.yml').and_return(daemon)

      expect(described_class.create('daemon.yml')).to be(daemon)
      expect(described_class.get).to be(daemon)
      expect { described_class.create('daemon.yml') }.to raise_error(
        RuntimeError,
        'Daemon already instantiated'
      )
      expect(described_class.get).to be(daemon)
      expect(described_class).to have_received(:new).once
    end
  end

  describe '#stop' do
    it 'drains client threads before shutting down command dependencies' do
      daemon = described_class.allocate
      server_class = Class.new do
        def stop; end
      end
      repo_class = Class.new do
        def stop; end
      end
      pool_class = Class.new do
        def begin_stop; end

        def all_stop; end
      end
      server = instance_spy(server_class)
      server_thread = instance_double(Thread, join: nil)
      repo = instance_spy(repo_class)
      pool = instance_spy(pool_class)
      lifecycle = instance_double(OsCtld::Container::Lifecycle, wake_all: nil)
      ct_class = Class.new do
        def lifecycle; end
      end
      ct = instance_double(ct_class, lifecycle:)

      stub_const('OsCtld::UserControl', Class.new do
        def self.stop; end
      end)
      stub_const('OsCtld::SendReceive', Class.new do
        def self.stop; end
      end)
      stub_const('OsCtld::DB::Repositories', Class.new do
        def self.each; end
      end)
      stub_const('OsCtld::DB::Pools', Class.new do
        def self.get; end
      end)
      stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      stub_const('OsCtld::Container::LifecycleExecutor', Class.new do
        def self.wake_all; end
      end)
      stub_const('OsCtld::CpuScheduler', Class.new do
        def self.shutdown; end
      end)
      stub_const('OsCtld::Monitor', Module.new)
      stub_const('OsCtld::Monitor::Master', Class.new do
        def self.stop; end
      end)

      daemon.instance_variable_set(:@server, server)
      daemon.instance_variable_set(:@server_thread, server_thread)
      daemon.instance_variable_set(:@phase, :prepared)
      daemon.instance_variable_set(:@prepare_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@stopping, false)
      allow(daemon).to receive(:log)
      allow(daemon).to receive(:exit!).and_raise(SystemExit)
      allow(FileUtils).to receive(:rm_f)
      allow(OsCtld::UserControl).to receive(:stop)
      allow(OsCtld::SendReceive).to receive(:stop)
      allow(OsCtld::DB::Repositories).to receive(:each).and_yield(repo)
      allow(OsCtld::DB::Pools).to receive(:get).and_return([pool])
      allow(OsCtld::DB::Containers).to receive(:get).and_return([ct])
      allow(OsCtld::Container::LifecycleExecutor).to receive(:wake_all)
      allow(OsCtld::Hook).to receive(:run)
      allow(OsCtld::ThreadReaper).to receive(:drain)
      allow(OsCtld::ThreadReaper).to receive(:stop)
      allow(OsCtld::Eventd).to receive(:shutdown)
      allow(OsCtld::CpuScheduler).to receive(:shutdown)
      allow(OsCtld::Monitor::Master).to receive(:stop)
      allow(OsCtld::LockRegistry).to receive(:stop)

      expect { daemon.stop }.to raise_error(SystemExit)

      expect(lifecycle).to have_received(:wake_all).ordered
      expect(OsCtld::Container::LifecycleExecutor).to have_received(:wake_all).ordered
      expect(server).to have_received(:stop).ordered
      expect(server_thread).to have_received(:join).ordered
      expect(OsCtld::ThreadReaper).to have_received(:drain).with(group: :management).ordered
      expect(pool).to have_received(:begin_stop).ordered
      expect(pool).to have_received(:all_stop).ordered
      expect(OsCtld::UserControl).to have_received(:stop).ordered
      expect(OsCtld::SendReceive).to have_received(:stop).ordered
      expect(OsCtld::ThreadReaper).to have_received(:stop).ordered
      expect(OsCtld::Eventd).to have_received(:shutdown).ordered
      expect(repo).to have_received(:stop).ordered
      expect(OsCtld::CpuScheduler).to have_received(:shutdown).ordered
      expect(OsCtld::Monitor::Master).to have_received(:stop).ordered
      expect(daemon).to have_received(:exit!).with(true).ordered
    end

    it 'prepares lifecycle operations before stopping callback services' do
      daemon = described_class.allocate
      restart = Struct.new(:drain_timeout, :cleanup_timeout).new(0, 0)
      config = Struct.new(:restart).new(restart)

      daemon.instance_variable_set(:@config, config)
      daemon.instance_variable_set(:@phase, :ready)
      daemon.instance_variable_set(:@prepare_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@stopping, false)
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@pre_stop_hooks_ran, false)

      allow(daemon).to receive(:log)
      allow(daemon).to receive(:pause_autostarts)
      allow(daemon).to receive_messages(
        run_pre_stop_hooks_once: true,
        lifecycle_restart_blockers: []
      )

      expect(daemon.prepare_stop).to be(true)
      expect(daemon.phase).to eq(:prepared)
      expect(daemon.lifecycle_admission?).to be(false)
      expect(daemon).to have_received(:pause_autostarts).ordered
      expect(daemon).to have_received(:run_pre_stop_hooks_once).ordered
    end

    it 'serializes the prepared-to-stopping transition against resume' do
      daemon = described_class.allocate
      prepared = Queue.new
      release_prepare = Queue.new
      stop_result = Queue.new
      resume_attempted = Queue.new
      resume_result = Queue.new

      daemon.instance_variable_set(:@phase, :ready)
      daemon.instance_variable_set(:@lifecycle_admission, true)
      daemon.instance_variable_set(:@prepare_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@stopping, false)

      allow(daemon).to receive(:prepare_stop_locked) do
        daemon.instance_variable_set(:@phase, :prepared)
        daemon.instance_variable_set(:@lifecycle_admission, false)
        prepared << true
        release_prepare.pop
        true
      end
      allow(daemon).to receive(:log) do |_level, message|
        raise 'stop transition committed' if message.start_with?('Stopping daemon')
      end

      stop_thread = Thread.new do
        daemon.stop
      rescue RuntimeError => e
        stop_result << e.message
      end
      prepared.pop
      prepare_mutex = daemon.instance_variable_get(:@prepare_mutex)
      mutex_acquired = prepare_mutex.try_lock
      prepare_mutex.unlock if mutex_acquired
      expect(mutex_acquired).to be(false)

      resume_thread = Thread.new do
        resume_attempted << true
        resume_result << daemon.resume
      end
      resume_attempted.pop

      release_prepare << true
      join_thread!(stop_thread)
      join_thread!(resume_thread)

      expect(stop_result.pop).to eq('stop transition committed')
      expect(resume_result.pop).to be(false)
      expect(daemon.phase).to eq(:stopping)
      expect(daemon.lifecycle_admission?).to be(false)
    ensure
      release_prepare << true if stop_thread&.alive?
      join_thread!(stop_thread) if stop_thread
      join_thread!(resume_thread) if resume_thread
    end

    it 'keeps callback services available when exact ownership cannot settle' do
      daemon = described_class.allocate
      restart = Struct.new(:drain_timeout, :cleanup_timeout).new(0, 0)
      config = Struct.new(:restart).new(restart)
      ct = Struct.new(:pool, :id).new(Struct.new(:name).new('tank'), '101')
      blocker = {
        type: 'container_generation',
        run_id: 'tank:101:run-1',
        phase: 'running',
        effect: nil
      }

      daemon.instance_variable_set(:@config, config)
      daemon.instance_variable_set(:@phase, :ready)
      daemon.instance_variable_set(:@prepare_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@stopping, false)
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@pre_stop_hooks_ran, false)

      allow(daemon).to receive(:log)
      allow(daemon).to receive(:pause_autostarts)
      allow(daemon).to receive_messages(
        run_pre_stop_hooks_once: true,
        lifecycle_restart_blockers: [[ct, blocker]]
      )
      allow(daemon).to receive(:interrupt_lifecycle_blockers)

      expect(daemon.prepare_stop).to be(false)
      expect(daemon.phase).to eq(:drain_failed)
      expect(daemon.stopping?).to be(false)
      expect(daemon).to have_received(:interrupt_lifecycle_blockers)
        .with(
          [[ct, blocker]],
          signal: 'TERM'
        )
      expect(daemon).to have_received(:interrupt_lifecycle_blockers)
        .with(
          [[ct, blocker]],
          signal: 'KILL'
        )
    end

    it 'leaves unowned processes alive beside an attributable generation' do
      daemon = described_class.allocate
      restart = Struct.new(:drain_timeout, :cleanup_timeout).new(0, 0)
      config = Struct.new(:restart).new(restart)
      lifecycle_class = Class.new do
        def daemon_restart_processes(*); end
      end
      lifecycle = instance_double(
        lifecycle_class,
        daemon_restart_processes: []
      )
      ct = Struct.new(:pool, :id, :lifecycle).new(
        Struct.new(:name).new('tank'),
        '101',
        lifecycle
      )
      pid = Process.spawn('sleep', '30')
      generation_blocker = {
        type: 'container_generation',
        run_id: 'tank:101:run-1',
        phase: 'starting',
        effect: nil
      }
      unowned_blocker = {
        type: 'unowned_container_cgroup_processes',
        phase: 'stopped',
        processes: [
          {
            cgroup_path: 'osctl/pool.tank/user.root/ct.101/unowned',
            pids: [pid]
          }
        ]
      }
      recovery_class = stub_const(
        'OsCtld::Container::Recovery',
        Class.new do
          def initialize(*); end

          def kill_generation(*); end
        end
      )
      recovery = instance_double(recovery_class)

      daemon.instance_variable_set(:@config, config)
      daemon.instance_variable_set(:@phase, :ready)
      daemon.instance_variable_set(:@prepare_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@stopping, false)
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@pre_stop_hooks_ran, false)

      allow(daemon).to receive(:log)
      allow(daemon).to receive(:pause_autostarts)
      allow(daemon).to receive_messages(
        run_pre_stop_hooks_once: true,
        lifecycle_restart_blockers: [
          [ct, generation_blocker],
          [ct, unowned_blocker]
        ]
      )
      allow(recovery_class).to receive(:new).with(ct)
                                            .and_return(recovery)
      allow(recovery).to receive(:kill_generation) do
        Process.kill('KILL', pid)
      end

      expect(daemon.prepare_stop).to be(false)
      expect(daemon.phase).to eq(:drain_failed)
      expect { Process.kill(0, pid) }.not_to raise_error
      expect(recovery).not_to have_received(:kill_generation)
    ensure
      begin
        if pid
          Process.kill('TERM', pid)
          Process.wait(pid)
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end

    it 'fails a daemon pre-stop barrier instead of continuing to stop' do
      daemon = described_class.allocate
      restart = Struct.new(:hook_timeout).new(30)
      daemon.instance_variable_set(:@config, Struct.new(:restart).new(restart))
      hook_class = Class.new do
        def self.hook_name
          :pre_stop
        end
      end

      allow(OsCtld::Hook).to receive(:run).and_raise(OsCtld::HookFailed.new(
                                                       hook_class.new,
                                                       '/run/osctl/hooks/daemon/pre-stop',
                                                       1
                                                     ))
      allow(daemon).to receive(:log)

      expect(daemon.send(:run_pre_stop_hooks)).to be(false)
      expect(daemon).to have_received(:log).with(
        :error,
        include('Daemon pre-stop hook failed')
      )
    end

    it 'returns to readiness when a pre-stop barrier fails' do
      daemon = described_class.allocate
      restart = Struct.new(:drain_timeout, :cleanup_timeout).new(0, 0)
      config = Struct.new(:restart).new(restart)

      daemon.instance_variable_set(:@config, config)
      daemon.instance_variable_set(:@phase, :ready)
      daemon.instance_variable_set(:@lifecycle_admission, true)
      daemon.instance_variable_set(:@prepare_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@stopping, false)
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@pre_stop_hooks_ran, false)

      allow(daemon).to receive(:log)
      allow(daemon).to receive(:pause_autostarts)
      allow(daemon).to receive(:run_pre_stop_hooks_once).and_return(false)
      allow(daemon).to receive(:complete_readiness_safely) do
        daemon.instance_variable_set(:@phase, :ready)
        daemon.instance_variable_set(:@lifecycle_admission, true)
        true
      end

      expect(daemon.prepare_stop).to be(false)
      expect(daemon.phase).to eq(:ready)
      expect(daemon.lifecycle_admission?).to be(true)
      expect(daemon).to have_received(:complete_readiness_safely).once
    end

    it 'exposes the daemon lifecycle hook directory' do
      daemon = described_class.allocate

      expect(daemon.user_hook_script_dir).to eq(OsCtld::RunState::DAEMON_HOOK_DIR)
    end

    it 'builds daemon pre-stop hook environments' do
      hook = described_class::Hooks::PreStop.new(described_class.allocate, {})

      expect(hook.send(:environment)).to include(
        'OSCTL_HOOK_NAME' => 'pre-stop',
        'OSCTL_DAEMON_STATE' => 'stopping',
        'OSCTL_DAEMON_PID' => Process.pid.to_s
      )
    end
  end

  describe '#join_stop_thread' do
    it 'keeps the setup thread alive until signal-driven cleanup finishes' do
      daemon = described_class.allocate
      release = Queue.new
      stop_thread = Thread.new { release.pop }
      daemon.instance_variable_set(:@stop_thread, stop_thread)

      setup_thread = Thread.new { daemon.send(:join_stop_thread) }
      setup_thread.join(0.05)

      expect(setup_thread).to be_alive

      release << true
      join_thread!(setup_thread)
      join_thread!(stop_thread)
    ensure
      release << true if stop_thread&.alive?
      join_thread!(setup_thread) if setup_thread
      join_thread!(stop_thread) if stop_thread
    end
  end

  describe '#admit_lifecycle!' do
    it 'allows admitted command continuations but rejects new work while draining' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@phase, :draining)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)

      expect do
        daemon.admit_lifecycle!(continuation: true)
      end.not_to raise_error
      expect do
        daemon.admit_lifecycle!(internal: true)
      end.to raise_error(OsCtld::CommandFailed, /admission is closed/)
    end

    it 'admits only explicitly tagged recovery before global readiness' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)

      expect do
        daemon.admit_lifecycle!(internal: true)
      end.to raise_error(OsCtld::CommandFailed, /admission is closed/)
      expect do
        daemon.admit_lifecycle!(internal: true, recovery: true)
      end.not_to raise_error
    end
  end

  describe 'startup readiness' do
    it 'cannot publish readiness while global startup reconciliation is running' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@initialized, false)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@lifecycle_admission_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, { 'early-pool' => {} })
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@resume_hooks_complete, false)

      allow(daemon).to receive(:complete_readiness).and_call_original
      allow(daemon).to receive(:run_resume_hooks).and_return(true)

      daemon.clear_recovery_failure('early-pool')

      expect(daemon).not_to have_received(:complete_readiness)
      expect(daemon.ready?).to be(false)
      expect(daemon.lifecycle_admission?).to be(false)
    end

    it 'drains direct restart requests behind startup reconciliation' do
      daemon = described_class.allocate
      restart = Struct.new(:drain_timeout, :cleanup_timeout).new(2, 0)
      config = Struct.new(:restart).new(restart)
      startup_entered = Queue.new
      finish_startup = Queue.new

      daemon.instance_variable_set(:@config, config)
      daemon.instance_variable_set(:@initialized, false)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@lifecycle_admission_mutex, Mutex.new)
      daemon.instance_variable_set(:@lifecycle_tasks, {})
      daemon.instance_variable_set(:@prepare_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@stopping, false)
      daemon.instance_variable_set(:@pre_stop_hooks_ran, false)

      pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.get; end
      end)
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(pools).to receive(:get).and_return([])
      allow(containers).to receive(:get).and_return([])
      allow(daemon).to receive(:log)
      allow(daemon).to receive(:run_pre_stop_hooks_once).and_return(true)

      startup_thread = Thread.new do
        daemon.send(:with_startup_lifecycle_task) do
          startup_entered << true
          finish_startup.pop
        end
      end
      startup_entered.pop

      prepare_thread = Thread.new { daemon.prepare_stop }
      Timeout.timeout(1) { sleep(0.01) until daemon.phase == :draining }

      expect(prepare_thread).to be_alive
      expect(daemon.send(:lifecycle_restart_blockers)).to contain_exactly(
        [
          nil,
          include(
            type: 'daemon_lifecycle_task',
            kind: 'daemon_startup_reconciliation'
          )
        ]
      )

      finish_startup << true
      expect(startup_thread.value).to be(true)
      expect(prepare_thread.value).to be(true)
      expect(daemon.phase).to eq(:prepared)
    ensure
      finish_startup << true if finish_startup && startup_thread&.alive?
      startup_thread&.join
      prepare_thread&.join
    end

    it 'does not start autostarts until all recovery failures clear' do
      daemon = described_class.allocate
      pool_class = Class.new do
        def name; end

        def autostart(**); end

        def resume_autostart(**); end
      end
      pool = instance_spy(pool_class, name: 'tank')

      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(
        :@config,
        Struct.new(:restart).new(Struct.new(:hook_timeout).new(30))
      )
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, { 'ct1' => {} })
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@resume_hooks_complete, false)
      daemon.instance_variable_set(:@autostart_enabled, true)
      daemon.instance_variable_set(:@autostarts_started, false)

      pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.get; end
      end)
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(pools).to receive(:get).and_return([pool])
      allow(containers).to receive(:get).and_return([])
      allow(daemon).to receive(:run_resume_hooks).and_return(true)

      expect(daemon.send(:complete_readiness)).to be(false)
      expect(pool).not_to have_received(:autostart)
      expect(daemon).not_to have_received(:run_resume_hooks)

      daemon.clear_recovery_failure('ct1')

      expect(daemon.ready?).to be(true)
      expect(daemon.lifecycle_admission?).to be(true)
      expect(pool).to have_received(:autostart).once
    end

    it 'lets a drain win while slow ready-service activation is in progress' do
      daemon = described_class.allocate
      restart = Struct.new(:drain_timeout, :cleanup_timeout).new(0, 0)
      config = Struct.new(:restart).new(restart)
      activation_started = Queue.new
      finish_activation = Queue.new
      activation_epoch = nil

      daemon.instance_variable_set(:@config, config)
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@lifecycle_admission_mutex, Mutex.new)
      daemon.instance_variable_set(:@prepare_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@stopping, false)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@resume_hooks_complete, false)
      daemon.instance_variable_set(:@resume_hook_running, false)
      daemon.instance_variable_set(:@pre_stop_hooks_ran, false)

      allow(daemon).to receive(:log)
      allow(daemon).to receive_messages(run_resume_hooks: true, lifecycle_restart_blockers: [])
      allow(daemon).to receive(:pause_autostarts)
      allow(daemon).to receive(:run_pre_stop_hooks_once).and_return(true)
      allow(daemon).to receive(:activate_ready_services) do |epoch|
        activation_epoch = epoch
        expect(daemon.phase).to eq(:ready)
        activation_started << true
        finish_activation.pop
      end

      readiness_thread = Thread.new { daemon.send(:complete_readiness) }
      activation_started.pop

      expect(daemon.prepare_stop).to be(true)

      expect(daemon.phase).to eq(:prepared)
      expect(daemon).to have_received(:pause_autostarts).once

      unpaused = false
      expect(
        daemon.send(:activate_autostarts, activation_epoch, :start) do
          unpaused = true
        end
      ).to be(false)
      expect(unpaused).to be(false)

      finish_activation << true
      expect(readiness_thread.value).to be(true)
    end

    it 'drains a registered pre-autostart hook before becoming prepared' do
      daemon = described_class.allocate
      restart = Struct.new(
        :drain_timeout,
        :cleanup_timeout,
        :hook_timeout
      ).new(2, 0, 1)
      config = Struct.new(:restart).new(restart)
      hook_started = Queue.new
      finish_hook = Queue.new
      pool_class = Class.new do
        attr_reader :name

        def initialize(name, hook_started, finish_hook)
          @name = name
          @hook_started = hook_started
          @finish_hook = finish_hook
        end

        def autostart(**)
          @hook_started << true
          @finish_hook.pop
        end
      end
      pool = pool_class.new('tank', hook_started, finish_hook)

      daemon.instance_variable_set(:@config, config)
      daemon.instance_variable_set(:@phase, :ready)
      daemon.instance_variable_set(:@lifecycle_admission, true)
      daemon.instance_variable_set(:@lifecycle_admission_mutex, Mutex.new)
      daemon.instance_variable_set(:@prepare_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@lifecycle_tasks, {})
      daemon.instance_variable_set(:@stopping, false)
      daemon.instance_variable_set(:@pre_stop_hooks_ran, false)

      pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.get; end
      end)
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(pools).to receive(:get).and_return([pool])
      allow(containers).to receive(:get).and_return([])
      allow(daemon).to receive(:log)
      allow(daemon).to receive(:pause_autostarts)
      allow(daemon).to receive(:run_pre_stop_hooks_once).and_return(true)

      autostart_thread = Thread.new do
        daemon.send(:start_autostarts, activation: proc { |&block| block.call })
      end
      hook_started.pop
      prepare_thread = Thread.new { daemon.prepare_stop }

      Timeout.timeout(1) do
        sleep(0.01) until daemon.phase == :draining
      end
      expect(prepare_thread).to be_alive

      finish_hook << true

      expect(autostart_thread.value).to eq([pool])
      expect(prepare_thread.value).to be(true)
      expect(daemon.phase).to eq(:prepared)
    end

    it 'does not begin a pre-autostart hook after a drain wins admission' do
      daemon = described_class.allocate
      pool_class = Class.new do
        attr_reader :name

        def initialize(name)
          @name = name
        end

        def autostart(**); end
      end
      pool = instance_spy(pool_class, name: 'tank')

      daemon.instance_variable_set(:@phase, :prepared)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@lifecycle_admission_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@lifecycle_tasks, {})

      pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.get; end
      end)
      allow(pools).to receive(:get).and_return([pool])
      allow(daemon).to receive(:log)

      expect do
        daemon.send(:start_autostarts, activation: proc { |&block| block.call })
      end.not_to raise_error
      expect(pool).not_to have_received(:autostart)
    end

    it 'keeps readiness blocked until the post-resume hook succeeds' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@started_at, Time.now)
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@drain_blockers, [])
      daemon.instance_variable_set(:@resume_hooks_complete, false)
      daemon.instance_variable_set(:@resume_hook_running, false)
      daemon.instance_variable_set(:@autostart_enabled, false)
      daemon.instance_variable_set(:@autostarts_started, false)

      pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.get; end
      end)
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(pools).to receive(:get).and_return([])
      allow(containers).to receive(:get).and_return([])
      allow(daemon).to receive(:run_resume_hooks).and_return(false, true)
      allow(daemon).to receive(:schedule_resume_hook_retry)

      expect(daemon.send(:complete_readiness)).to be(false)
      expect(daemon.ready?).to be(false)
      expect(daemon.status.fetch(:failures)).to contain_exactly(
        include(key: 'daemon-post-resume')
      )

      daemon.clear_recovery_failure('daemon-post-resume')

      expect(daemon.ready?).to be(true)
      expect(daemon.lifecycle_admission?).to be(true)
      expect(daemon).to have_received(:run_resume_hooks).twice
      expect(daemon).to have_received(:schedule_resume_hook_retry).once
    end

    it 'restores the pause barrier when readiness changes during resume' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@lifecycle_admission_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@resume_hooks_complete, false)
      daemon.instance_variable_set(:@resume_hook_running, false)

      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(containers).to receive(:get).and_return([])
      allow(daemon).to receive(:run_resume_hooks) do
        daemon.record_recovery_failure('late-recovery', 'late failure')
        true
      end
      allow(daemon).to receive(:run_pre_stop_hooks).and_return(true)

      expect(daemon.send(:complete_readiness)).to be(false)
      expect(daemon.phase).to eq(:blocked)
      expect(daemon.lifecycle_admission?).to be(false)
      expect(daemon).to have_received(:run_pre_stop_hooks).once
    end

    it 'contains unexpected post-resume hook errors and keeps admission blocked' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@started_at, Time.now)
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@lifecycle_admission_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@drain_blockers, [])
      daemon.instance_variable_set(:@resume_hooks_complete, false)
      daemon.instance_variable_set(:@resume_hook_running, false)

      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(containers).to receive(:get).and_return([])
      allow(daemon).to receive(:run_resume_hooks).and_raise('hook setup failed')
      allow(daemon).to receive(:log)
      allow(daemon).to receive(:lifecycle_state_changed)

      expect(daemon.send(:complete_readiness_safely)).to be(false)

      expect(daemon.phase).to eq(:blocked)
      expect(daemon.lifecycle_admission?).to be(false)
      expect(daemon.status.fetch(:failures)).to contain_exactly(
        include(
          key: 'daemon-readiness',
          message: 'readiness evaluation failed: hook setup failed',
          details: { exception: 'RuntimeError' }
        )
      )
      expect(daemon).to have_received(:lifecycle_state_changed).once
    end

    it 'retries blocked readiness without another lifecycle notification' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@phase, :blocked)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@stopping, false)
      daemon.instance_variable_set(:@readiness_retry_mutex, Mutex.new)
      daemon.instance_variable_set(:@readiness_retry, nil)

      attempts = 0
      allow(daemon).to receive(:complete_readiness_safely) do
        attempts += 1
        if attempts == 2
          daemon.instance_variable_set(:@phase, :ready)
          true
        else
          false
        end
      end
      allow(daemon).to receive(:sleep)
      allow(OsCtld::ThreadReaper).to receive(:add)

      daemon.lifecycle_state_changed
      Timeout.timeout(1) do
        sleep(0.01) until daemon.instance_variable_get(:@readiness_retry).nil?
      end

      expect(attempts).to eq(2)
      expect(OsCtld::ThreadReaper).to have_received(:add).once
    end

    it 'discards a stale retry notification after readiness opens' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@phase, :blocked)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@stopping, false)
      daemon.instance_variable_set(:@lifecycle_admission_mutex, Mutex.new)
      daemon.instance_variable_set(:@lifecycle_tasks, {})
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@resume_hooks_complete, true)
      daemon.instance_variable_set(:@resume_hook_running, false)
      daemon.instance_variable_set(:@readiness_epoch, 0)
      daemon.instance_variable_set(:@readiness_retry_mutex, Mutex.new)
      daemon.instance_variable_set(:@readiness_retry, nil)

      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(containers).to receive(:get).and_return([])

      blocker_scans = 0
      allow(daemon).to receive(:lifecycle_restart_blockers) do
        blocker_scans += 1
        if blocker_scans == 1
          daemon.lifecycle_state_changed
          []
        else
          [[nil, { type: 'daemon_lifecycle_task' }]]
        end
      end
      allow(daemon).to receive(:activate_ready_services) do
        daemon.instance_variable_get(:@lifecycle_tasks)['autostart'] = true
      end
      allow(daemon).to receive(:sleep)
      allow(OsCtld::ThreadReaper).to receive(:add)

      daemon.lifecycle_state_changed
      Timeout.timeout(1) do
        sleep(0.01) until daemon.instance_variable_get(:@readiness_retry).nil?
      end

      expect(blocker_scans).to eq(1)
      expect(daemon.phase).to eq(:ready)
      expect(daemon.lifecycle_admission?).to be(true)
      expect(daemon).to have_received(:activate_ready_services).once
      expect(daemon).not_to have_received(:sleep)
    end

    it 'keeps polling when blocked phase returns during worker exit' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@phase, :blocked)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@stopping, false)

      retry_mutex = Mutex.new
      retry_mutex_calls = 0
      allow(retry_mutex).to receive(:synchronize).and_wrap_original do |method, &block|
        retry_mutex_calls += 1

        if retry_mutex_calls == 2
          daemon.instance_variable_set(:@phase, :blocked)
          daemon.lifecycle_state_changed
        end

        method.call(&block)
      end
      daemon.instance_variable_set(:@readiness_retry_mutex, retry_mutex)
      daemon.instance_variable_set(:@readiness_retry, nil)

      attempts = 0
      allow(daemon).to receive(:complete_readiness_safely) do
        attempts += 1
        daemon.instance_variable_set(
          :@phase,
          attempts == 1 ? :draining : :ready
        )
      end
      allow(daemon).to receive(:sleep)
      allow(OsCtld::ThreadReaper).to receive(:add)

      daemon.lifecycle_state_changed
      Timeout.timeout(1) do
        sleep(0.01) until daemon.instance_variable_get(:@readiness_retry).nil?
      end

      expect(attempts).to eq(2)
      expect(daemon.phase).to eq(:ready)
      expect(daemon).to have_received(:sleep).once
      expect(OsCtld::ThreadReaper).to have_received(:add).once
    end

    it 'withdraws readiness when ready-service activation raises unexpectedly' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@started_at, Time.now)
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@lifecycle_admission_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@drain_blockers, [])
      daemon.instance_variable_set(:@resume_hooks_complete, true)
      daemon.instance_variable_set(:@resume_hook_running, false)
      daemon.instance_variable_set(:@readiness_epoch, 0)

      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(containers).to receive(:get).and_return([])
      allow(daemon).to receive(:activate_ready_services)
        .and_raise('autostart setup failed')
      allow(daemon).to receive(:log)
      allow(daemon).to receive(:lifecycle_state_changed)

      expect(daemon.send(:complete_readiness_safely)).to be(false)

      expect(daemon.phase).to eq(:blocked)
      expect(daemon.lifecycle_admission?).to be(false)
      expect(daemon.status.fetch(:failures)).to contain_exactly(
        include(
          key: 'daemon-readiness',
          message: 'readiness evaluation failed: autostart setup failed'
        )
      )
    end

    it 'records unmanaged live cgroups as readiness-blocking orphans' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])

      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(containers).to receive(:get).and_return([])
      allow(OsCtld::CGroup).to receive(:runtime_container_cgroups).and_return(
        [
          {
            cgroup_path: 'osctl/pool.tank/user.root/ct.999',
            processes: [
              {
                cgroup_path: 'osctl/pool.tank/user.root/ct.999/payload',
                pids: [123]
              }
            ],
            pids: [123]
          }
        ]
      )
      allow(OsCtld::CGroup).to receive(:runtime_cgroup_pids)
        .with('osctl/pool.tank/user.root/ct.999/payload')
        .and_return([123])

      daemon.send(:inventory_runtime_orphans)

      expect(daemon.instance_variable_get(:@orphans)).to contain_exactly(
        include(
          type: 'unconfigured_container_cgroup',
          cgroup_path: 'osctl/pool.tank/user.root/ct.999',
          pids: [123]
        )
      )
    end

    it 'records an adopted running container without a live manager' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      lifecycle_class = Class.new do
        def active_run; end

        def runtime_generations; end
      end
      lifecycle = instance_double(
        lifecycle_class,
        active_run: {
          'hazards' => ['adopted legacy runtime'],
          'legacy_managers' => []
        },
        runtime_generations: [
          {
            'resources' => {
              'cgroup_root' => 'osctl/pool.tank/user.root/ct.101'
            }
          }
        ]
      )
      pool_class = Class.new do
        def name; end
      end
      ct_class = Class.new do
        def base_cgroup_path; end

        def running?; end

        def lifecycle; end

        def pool; end

        def id; end

        def state; end

        def init_pid; end
      end
      ct = instance_double(
        ct_class,
        base_cgroup_path: 'osctl/pool.tank/user.root/ct.101',
        running?: true,
        lifecycle:,
        pool: instance_double(pool_class, name: 'tank'),
        id: '101',
        state: :running,
        init_pid: 4321
      )
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(containers).to receive(:get).and_return([ct])
      allow(OsCtld::CGroup).to receive(:runtime_container_cgroups).and_return([])

      daemon.send(:inventory_runtime_orphans)

      expect(daemon.instance_variable_get(:@orphans)).to contain_exactly(
        include(
          type: 'unowned_container_runtime',
          pool: 'tank',
          id: '101',
          init_pid: 4321
        )
      )
    end

    it 'records a frozen adopted container with only a stale manager identity' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@initialized, true)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      lifecycle = instance_double(
        OsCtld::Container::Lifecycle,
        active_run: {
          'hazards' => ['adopted legacy runtime'],
          'legacy_managers' => [
            {
              'pid' => 999_999_999,
              'start_time_ticks' => 1,
              'kind' => 'legacy_wrapper'
            }
          ]
        },
        runtime_generations: [
          {
            'resources' => {
              'cgroup_root' => 'osctl/pool.tank/user.root/ct.101'
            }
          }
        ]
      )
      pool = Struct.new(:name).new('tank')
      ct = FakeObjects::FakeRuntimeContainer.new(
        pool:,
        id: '101',
        fresh_state: :frozen,
        state: :frozen,
        init_pid: 4321,
        base_cgroup_path: 'osctl/pool.tank/user.root/ct.101'
      )
      ct.lifecycle = lifecycle
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(containers).to receive(:get).and_return([ct])
      allow(OsCtld::CGroup).to receive(:runtime_container_cgroups).and_return([])

      daemon.send(:inventory_runtime_orphans)

      expect(daemon.instance_variable_get(:@orphans)).to contain_exactly(
        include(
          type: 'unowned_container_runtime',
          pool: 'tank',
          id: '101',
          state: 'frozen',
          reason: 'adopted legacy manager identity is not alive'
        )
      )
    end

    it 'records live processes in a configured stopped container cgroup' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@initialized, false)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      pool = Struct.new(:name).new('tank')
      ct = FakeObjects::FakeRuntimeContainer.new(
        pool:,
        id: '101',
        state: :stopped,
        base_cgroup_path: 'osctl/pool.tank/user.root/ct.101'
      )
      ct.lifecycle = Struct.new(:runtime_generations).new([])
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(containers).to receive(:get).and_return([ct])
      allow(OsCtld::CGroup).to receive(:runtime_container_cgroups).and_return(
        [
          {
            cgroup_path: 'osctl/pool.tank/user.root/ct.101',
            processes: [
              {
                cgroup_path: 'osctl/pool.tank/user.root/ct.101',
                pids: [4321]
              }
            ],
            pids: [4321]
          }
        ]
      )
      allow(OsCtld::CGroup).to receive(:runtime_cgroup_pids)
        .with('osctl/pool.tank/user.root/ct.101')
        .and_return([4321])

      daemon.send(:inventory_runtime_orphans)

      expect(daemon.instance_variable_get(:@orphans)).to contain_exactly(
        include(
          type: 'configured_container_unowned_processes',
          pool: 'tank',
          id: '101',
          state: 'stopped',
          pids: [4321]
        )
      )
    end

    it 'accepts payload runtime for an active running generation' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@initialized, false)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      pool = Struct.new(:name).new('tank')
      run = {
        'role' => 'active',
        'kind' => 'container',
        'phase' => 'running',
        'resources' => {
          'cgroup_root' =>
            'osctl/pool.tank/user.root/ct.101/runs/generation-1',
          'lxc_payload' =>
            'osctl/pool.tank/user.root/ct.101/runs/generation-1/user-owned/payload'
        }
      }
      lifecycle = Struct.new(:runtime_generations, :active_run).new([run], run)
      ct = FakeObjects::FakeRuntimeContainer.new(
        pool:,
        id: '101',
        state: :running,
        base_cgroup_path: 'osctl/pool.tank/user.root/ct.101'
      )
      ct.lifecycle = lifecycle
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(containers).to receive(:get).and_return([ct])
      allow(OsCtld::CGroup).to receive(:runtime_container_cgroups).and_return(
        [
          {
            cgroup_path: 'osctl/pool.tank/user.root/ct.101',
            processes: [
              {
                cgroup_path:
                  'osctl/pool.tank/user.root/ct.101/runs/generation-1/user-owned/payload/inner',
                pids: [4321]
              }
            ],
            pids: [4321]
          }
        ]
      )

      daemon.send(:inventory_runtime_orphans)

      expect(daemon.instance_variable_get(:@orphans)).to be_empty
    end

    it 'blocks an unrecorded descendant in a generation host-effects tree' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      pool = Struct.new(:name).new('tank')
      lifecycle = Struct.new(:runtime_generations).new(
        [
          {
            'role' => 'active',
            'kind' => 'container',
            'phase' => 'running',
            'processes' => {},
            'resources' => {
              'cgroup_root' =>
                'osctl/pool.tank/user.root/ct.101/runs/generation-1',
              'host_effects' =>
                'osctl/pool.tank/user.root/ct.101/runs/generation-1/host-effects',
              'lxc_payload' =>
                'osctl/pool.tank/user.root/ct.101/runs/generation-1/user-owned/payload'
            }
          }
        ]
      )
      ct = FakeObjects::FakeRuntimeContainer.new(
        pool:,
        id: '101',
        state: :running,
        base_cgroup_path: 'osctl/pool.tank/user.root/ct.101'
      )
      ct.lifecycle = lifecycle
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(containers).to receive(:get).and_return([ct])
      host_effects =
        'osctl/pool.tank/user.root/ct.101/runs/generation-1/host-effects/child'
      allow(OsCtld::CGroup).to receive(:runtime_container_cgroups).and_return(
        [
          {
            cgroup_path: ct.base_cgroup_path,
            processes: [
              { cgroup_path: host_effects, pids: [Process.pid] }
            ],
            pids: [Process.pid]
          }
        ]
      )
      allow(OsCtld::CGroup).to receive(:runtime_cgroup_pids)
        .with(host_effects)
        .and_return([Process.pid])

      blockers = daemon.send(:runtime_cgroup_restart_blockers)

      expect(blockers).to contain_exactly(
        [
          ct,
          include(
            type: 'unowned_container_cgroup_processes',
            phase: 'running',
            processes: contain_exactly(
              include(cgroup_path: host_effects, pids: [Process.pid])
            )
          )
        ]
      )
    end

    it 'ignores a suspected unowned process which vanished during inventory' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@initialized, false)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      pool = Struct.new(:name).new('tank')
      ct = FakeObjects::FakeRuntimeContainer.new(
        pool:,
        id: '101',
        state: :stopped,
        base_cgroup_path: 'osctl/pool.tank/user.root/ct.101'
      )
      ct.lifecycle = Struct.new(:runtime_generations).new([])
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(containers).to receive(:get).and_return([ct])
      allow(OsCtld::CGroup).to receive(:runtime_container_cgroups).and_return(
        [
          {
            cgroup_path: 'osctl/pool.tank/user.root/ct.101',
            processes: [
              {
                cgroup_path: 'osctl/pool.tank/user.root/ct.101/stale',
                pids: [4321]
              }
            ],
            pids: [4321]
          }
        ]
      )
      allow(OsCtld::CGroup).to receive(:runtime_cgroup_pids)
        .with('osctl/pool.tank/user.root/ct.101/stale')
        .and_return([])

      daemon.send(:inventory_runtime_orphans)

      expect(daemon.instance_variable_get(:@orphans)).to be_empty
    end

    it 'persists a stopped legacy handoff intent before fulfilling it' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@initialized, false)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@lifecycle_admission_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      lifecycle_class = Class.new do
        def persist_running_intent(**); end

        def desired_state; end
      end
      lifecycle = instance_double(
        lifecycle_class,
        desired_state: :running
      )
      pool = Struct.new(:name).new('tank')
      ct = FakeObjects::FakeRuntimeContainer.new(
        pool:,
        id: '101'
      )
      ct.lifecycle = lifecycle
      handoff = instance_double(
        OsCtld::UpgradeHandoff,
        valid?: true,
        remaining: [%w[tank 101]],
        empty?: true,
        fulfil: nil,
        complete: true
      )
      daemon.instance_variable_set(:@upgrade_handoff, handoff)
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(*); end
      end)
      allow(containers).to receive(:find).with('101', 'tank').and_return(ct)
      allow(lifecycle).to receive(:persist_running_intent)
        .with(source: 'legacy-runtime-upgrade')
        .and_return('intent-1')

      daemon.send(:persist_upgrade_handoff)

      expect(lifecycle).to have_received(:persist_running_intent).ordered
      expect(handoff).to have_received(:fulfil).with(ct).ordered
      expect(handoff).to have_received(:complete).ordered
    end

    it 'keeps readiness blocked for an invalid current-boot handoff' do
      daemon = described_class.allocate
      daemon.instance_variable_set(:@started_at, Time.now)
      daemon.instance_variable_set(:@initialized, false)
      daemon.instance_variable_set(:@phase, :starting)
      daemon.instance_variable_set(:@lifecycle_admission, false)
      daemon.instance_variable_set(:@state_mutex, Mutex.new)
      daemon.instance_variable_set(:@state_cv, ConditionVariable.new)
      daemon.instance_variable_set(:@recovery_failures, {})
      daemon.instance_variable_set(:@orphans, [])
      daemon.instance_variable_set(:@drain_blockers, [])
      handoff = instance_double(
        OsCtld::UpgradeHandoff,
        valid?: false,
        error: 'unsupported schema 2',
        complete: false
      )
      daemon.instance_variable_set(:@upgrade_handoff, handoff)
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(containers).to receive(:get).and_return([])

      daemon.send(:persist_upgrade_handoff)

      expect(daemon.status.fetch(:failures)).to contain_exactly(
        include(
          key: 'upgrade-handoff',
          message: 'invalid legacy runtime handoff: unsupported schema 2'
        )
      )
      expect(handoff).not_to have_received(:complete)
    end

    it 'escalates the exact residual generation named by a blocker' do
      daemon = described_class.allocate
      lifecycle_class = Class.new do
        def daemon_restart_processes(*); end
      end
      lifecycle = instance_double(lifecycle_class)
      ct_class = Class.new do
        def lifecycle; end

        def pool; end

        def id; end
      end
      pool_class = Class.new do
        def name; end
      end
      ct = instance_double(
        ct_class,
        lifecycle:,
        pool: instance_double(pool_class, name: 'tank'),
        id: 'ct1'
      )
      blocker = {
        type: 'container_generation',
        run_id: 'tank:ct1:residual',
        role: 'residual',
        phase: 'cleaning',
        effect: { 'type' => 'cleanup' }
      }
      allow(lifecycle).to receive(:daemon_restart_processes)
        .with('tank:ct1:residual')
        .and_return([])

      daemon.send(
        :interrupt_lifecycle_blockers,
        [[ct, blocker]],
        signal: 'TERM'
      )

      expect(lifecycle).to have_received(:daemon_restart_processes)
        .with('tank:ct1:residual')
    end
  end

  describe OsCtld::Daemon::ClientHandler do
    before do
      allow(OsCtld::Eventd).to receive(:report)
    end

    it 'requests the active command to stop without closing the client socket' do
      with_socket_pair do |server_sock, _client_sock|
        handler = described_class.new(server_sock, {})
        cmd_class = Class.new do
          def request_stop; end
        end
        cmd = instance_double(cmd_class, request_stop: nil)

        handler.instance_variable_set(:@cmd, cmd)

        handler.request_stop

        expect(cmd).to have_received(:request_stop).once
        expect(server_sock).not_to be_closed
      end
    end

    it 'does not retain completed commands as active' do
      with_socket_pair do |server_sock, _client_sock|
        handler = described_class.new(server_sock, {})
        cmd_class = Class.new do
          def initialize(_opts, id:, handler:); end

          def base_execute; end

          def request_stop; end
        end
        cmd = instance_double(
          cmd_class,
          base_execute: { status: true, output: 'done' },
          request_stop: nil
        )

        allow(OsCtld::Command).to receive(:find).with(:ping).and_return(cmd_class)
        allow(OsCtld::Command).to receive(:get_id).and_return(42)
        allow(cmd_class).to receive(:new)
          .with({}, id: 42, handler:)
          .and_return(cmd)

        expect(handler.handle_cmd(cmd: 'ping', opts: {})).to eq(
          status: true,
          output: 'done'
        )

        handler.request_stop

        expect(cmd).not_to have_received(:request_stop)
      end
    end
  end
end
