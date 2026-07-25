# frozen_string_literal: true

# rubocop:disable Lint/ConstantDefinitionInBlock, Lint/StructNewOverride, RSpec/DescribeClass, RSpec/LeakyConstantDeclaration, RSpec/VerifiedDoubles

require 'fileutils'
require 'ostruct'
require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/container_control/command'
require 'osctld/container/lifecycle_executor'
require 'osctld/console'
require 'osctld/switch_user'
require 'osctld/thread_reaper'
require 'osctld/utils/container'
require 'osctld/utils/switch_user'
require 'osctld/commands/container/start'
require 'osctld/commands/container/stop'
require 'osctld/commands/container/restart'
require 'osctld/commands/container/boot'
require 'osctld/commands/container/delete'
require 'osctld/commands/container/freeze'
require 'osctld/commands/container/unfreeze'
require 'osctld/commands/container/reconfigure'

RSpec.describe 'container lifecycle commands' do
  Event = Struct.new(:type, :opts, keyword_init: true)

  def build_history
    stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
  end

  def build_db_containers
    stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end

      def self.remove(_ct); end
    end)
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
    allow(build_history).to receive(:log)
  end

  describe OsCtld::Commands::Container::Start do
    let(:autostart_plan) do
      Class.new do
        attr_reader :enqueue_calls, :start_calls

        def initialize
          @enqueue_calls = []
          @start_calls = []
        end

        def enqueue(ct, **opts)
          enqueue_calls << [ct, opts]
        end

        def start_ct(ct, **opts)
          start_calls << [ct, opts]
          :queued
        end
      end.new
    end

    let(:pool) do
      Struct.new(:name, :console_dir, :autostart_plan).new('tank', '/tmp/console', autostart_plan)
    end

    let(:ct) { Struct.new(:id, :pool).new('ct1', pool) }

    it 'enqueues queued starts when waiting is disabled' do
      command = described_class.new({ queue: true, wait: false, priority: 10 }, {})

      expect(command.send(:start_queued, ct)).to eq(status: true, output: nil)
      expect(autostart_plan.enqueue_calls).to eq(
        [[ct, { priority: 10, start_opts: command.opts }]]
      )
    end

    it 'returns the timeout-style response when the queued start times out' do
      allow(autostart_plan).to receive(:start_ct).and_return(nil)
      command = described_class.new({ queue: true, wait: 5, priority: 20 }, {})

      expect(command.send(:start_queued, ct)).to eq(status: true, output: 'Timed out')
      expect(autostart_plan).to have_received(:start_ct).with(
        ct,
        priority: 20,
        start_opts: command.opts,
        client_handler: nil
      )
    end

    it 'rejects starts when the container cannot start' do
      container = Struct.new(:can_start?, :state).new(false, :stopped)
      command = described_class.new({ wait: 'infinity' }, {})

      expect { command.execute(container) }
        .to raise_error(OsCtld::CommandFailed, 'start not available')
    end

    it 'joins the active lifecycle run when the container is already running' do
      run_id = double(to_s: 'tank:ct1:run-1')
      request = Struct.new(
        :action,
        :run_id,
        :revision,
        :intent_id,
        :warning,
        keyword_init: true
      ).new(action: :running, run_id:, revision: 7, intent_id: 'intent-1')
      lifecycle = double(request_start: request, active_run_id: run_id)
      container = Struct.new(:can_start?, :lifecycle) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(true, lifecycle)
      command = described_class.new({ wait: 'infinity' }, {})

      expect(command.execute(container)).to eq(
        status: true,
        output: {
          run_id: 'tank:ct1:run-1',
          lifecycle_revision: 7,
          lifecycle_state: 'running'
        }
      )
    end

    it 'locks group membership through stopped launch admission' do
      run_id = double(to_s: 'tank:ct1:run-1')
      request = OsCtld::Container::Lifecycle::Request.new(
        action: :launch,
        run_id:,
        revision: 8,
        intent_id: 'intent-1'
      )
      lifecycle = double(
        active_run_id: nil,
        request_start: request
      )
      group = Struct.new(:name).new('/default')
      container = Struct.new(
        :can_start?,
        :lifecycle,
        :group,
        :pool
      ) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(true, lifecycle, group, pool)
      command = described_class.new({ wait: false }, {})
      lock_held = false
      call_order = []
      allow(container).to receive(:manipulate) do |_holder, **, &callback|
        lock_held = true
        callback.call
      ensure
        lock_held = false
      end
      allow(command).to receive(:call_cmd) do
        call_order << :group_policy
        expect(lock_held).to be(true)
        { status: true, output: nil }
      end
      allow(lifecycle).to receive(:request_start) do
        call_order << :lifecycle
        expect(lock_held).to be(true)
        request
      end
      allow(command).to receive(:launch_in_background)

      expect(command.execute(container)).to eq(
        status: true,
        output: {
          run_id: 'tank:ct1:run-1',
          lifecycle_revision: 8,
          lifecycle_state: 'accepted'
        }
      )
      expect(command).to have_received(:launch_in_background)
        .with(container, request)
      expect(command).to have_received(:call_cmd).with(
        OsCtld::Commands::Group::CGParamApply,
        name: '/default',
        pool: 'tank',
        manipulation_lock: 'wait',
        only_cpuset: true
      )
      expect(lifecycle).to have_received(:request_start)
      expect(call_order).to eq(%i[group_policy lifecycle])
    end

    it 'maps dataset mount failures to command errors' do
      run_conf = Struct.new(:mount).new(nil)
      allow(run_conf).to receive(:mount)
        .and_raise(OsCtld::SystemCommandFailed.new('mount', 1, 'no dataset'))
      mounts = Struct.new(:prune).new(nil)
      allow(mounts).to receive(:prune)
      container = Struct.new(
        :impermanence,
        :distribution,
        :mounts,
        keyword_init: true
      ).new(
        impermanence: false,
        distribution: 'almalinux',
        mounts:
      )
      command = described_class.new({}, {})
      allow(command).to receive(:ensure_effect!).and_return(true)

      expect do
        command.send(
          :launch_run,
          container,
          run_conf,
          'run-1',
          'effect-1',
          'intent-1',
          report_progress: true
        )
      end.to raise_error(
        OsCtld::CommandFailed,
        "failed to mount dataset: command 'mount' exited with code '1', output: 'no dataset'"
      )
    end

    it 'accepts pre-start completion which races ahead of console return' do
      lifecycle = double(wait_for_launch_handoff: :complete)
      allow(lifecycle).to receive(:effect_current?)
      container = double(lifecycle:)
      run_conf = double
      callback_completed = false
      allow(OsCtld::Console).to receive(:connect_tty0) do
        callback_completed = true
      end
      allow(lifecycle).to receive(:wait_for_launch_handoff) do
        expect(callback_completed).to be(true)
        :complete
      end
      command = described_class.new({}, {})

      expect(
        command.send(
          :complete_launch_handoff,
          container,
          123,
          run_conf,
          'run-1',
          'effect-1'
        )
      ).to be(true)
      expect(OsCtld::Console).to have_received(:connect_tty0).with(
        container,
        123,
        run_conf,
        effect_id: 'effect-1',
        intent_id: nil
      )
      expect(lifecycle).not_to have_received(:effect_current?)
    end

    it 'waits for the exact lifecycle run to become running' do
      lifecycle = double(wait_for_start: :running, revision: 9)
      container = Struct.new(:lifecycle).new(lifecycle)
      run_id = double(to_s: 'tank:ct1:run-1')
      command = described_class.new({ wait: 5 }, {})

      expect(command.send(:wait_for_run, container, run_id, nil)).to eq(
        status: true,
        output: {
          run_id: 'tank:ct1:run-1',
          lifecycle_revision: 9,
          lifecycle_state: 'running'
        }
      )
    end

    it 'reports a lifecycle start timeout' do
      lifecycle = double(wait_for_start: :timeout)
      container = Struct.new(:lifecycle).new(lifecycle)
      command = described_class.new({ wait: 1 }, {})

      expect(command.send(:wait_for_run, container, 'run-1', nil)).to eq(
        status: false,
        message: 'timed out while waiting for container to start'
      )
    end

    it 'reports the exact lifecycle launch failure' do
      lifecycle = double(
        wait_for_start: :failed,
        run: { 'error' => 'mount failed' }
      )
      container = Struct.new(:lifecycle).new(lifecycle)
      command = described_class.new({ wait: 5 }, {})

      expect(command.send(:wait_for_run, container, 'run-1', nil)).to eq(
        status: false,
        message: 'mount failed'
      )
    end

    it 'retries a failed old run when a newer running intent is pending' do
      lifecycle = double(
        wait_for_start: :failed,
        run: {
          'error' => 'superseded',
          'launch_intent_id' => 'intent-1'
        },
        desired_state: :running,
        current_intent_id: 'intent-2'
      )
      container = Struct.new(:lifecycle).new(lifecycle)
      command = described_class.new({ wait: 5 }, {})

      expect(command.send(:wait_for_run, container, 'run-1', nil)).to eq(:retry)
    end

    it 'fails when osctld is shutting down while waiting' do
      lifecycle = double(wait_for_start: :shutdown)
      container = Struct.new(:lifecycle).new(lifecycle)
      command = described_class.new({ wait: 'infinity' }, {})

      expect(command.send(:wait_for_run, container, 'run-1', nil)).to eq(
        status: false,
        message: 'osctld is shutting down'
      )
    end

    it 'keeps an infinite start wait unbounded' do
      command = described_class.new({ wait: 'infinity' }, {})

      expect(command.send(:wait_deadline)).to be_nil
      expect(command.send(:remaining_wait, nil)).to be_nil
    end

    it 'does not report progress through a detached wait=false client' do
      command = described_class.new({ wait: false }, {})
      request = double
      container = double
      thread = instance_double(Thread)

      allow(command).to receive(:launch)
      allow(Thread).to receive(:new) do |&block|
        block.call
        thread
      end
      allow(OsCtld::ThreadReaper).to receive(:add)

      command.send(:launch_in_background, container, request)

      expect(command).to have_received(:launch).with(
        container,
        request,
        report_progress: false
      )
      expect(OsCtld::ThreadReaper).to have_received(:add).with(
        thread,
        nil,
        group: :durable_lifecycle
      )
    end

    it 'hands a ready cleanup effect from the start worker to the finalizer' do
      run_conf = double(run_id: 'run-1')
      lifecycle = double(claim_finalization: 'cleanup-1')
      container = double(lifecycle:)
      finalizer = stub_const(
        'OsCtld::Container::LifecycleFinalizer',
        Class.new do
          def self.spawn(*); end
        end
      )
      allow(finalizer).to receive(:spawn)
      command = described_class.new({}, {})

      command.send(
        :spawn_finalizer_if_ready,
        container,
        run_conf,
        'run-1'
      )

      expect(finalizer).to have_received(:spawn).with(
        container,
        run_conf,
        'cleanup-1'
      )
    end
  end

  describe OsCtld::Commands::Container::Stop do
    let(:autostart_plan) do
      Class.new do
        def stop_ct(_ct); end
      end.new
    end

    let(:pool) { Struct.new(:name, :autostart_plan).new('tank', autostart_plan) }

    def build_stop_container(state: :running, running: true, ephemeral: false, promise: nil)
      run_conf = Struct.new(:init_pid, :promise, :run_id) do
        def get_exit_promise
          promise
        end
      end.new(promise ? 4321 : nil, promise, 'run-1')
      request = Struct.new(
        :action,
        :run_id,
        :revision,
        :intent_id,
        keyword_init: true
      ).new(
        action: :stop,
        run_id: 'run-1',
        revision: 1,
        intent_id: 'intent-1'
      )
      lifecycle = Struct.new(:request, :wait_result) do
        attr_reader :waited_run_id, :stop_error

        def request_stop(**)
          request
        end

        def claim_effect(*)
          'effect-1'
        end

        def effect_current?(*)
          true
        end

        def set_effect_worker(*); end

        def effect_worker_exited(*); end

        def finish_effect(*); end

        def claim_finalization(*); end

        def fail_stop(_run_id, _effect_id, message)
          @stop_error = message
          self.wait_result = :stop_failed
        end

        def run(_run_id)
          { 'stop_error' => stop_error }
        end

        def wait_for_stop(run_id)
          @waited_run_id = run_id
          wait_result
        end
      end.new(request, :clean)
      cgparams = Struct.new do
        attr_reader :expanded

        def temporarily_expand_memory
          @expanded = true
        end
      end.new
      Struct.new(
        :id,
        :pool,
        :state,
        :cgparams,
        :run_conf,
        :cgroup_path,
        :lifecycle,
        keyword_init: true
      ) do
        attr_accessor :running_state, :ephemeral_state, :log_lines

        def running?
          running_state
        end

        def get_run_conf
          run_conf
        end

        def get_past_run_conf
          nil
        end

        def log(level, message)
          log_lines << [level, message]
        end

        def ephemeral?
          ephemeral_state
        end

        def manipulate(_holder, block:, &)
          yield
        end
      end.new(
        id: 'ct1',
        pool:,
        state:,
        cgparams:,
        run_conf:,
        cgroup_path: '/sys/fs/cgroup/osctl/ct.ct1',
        lifecycle:
      ).tap do |ct|
        ct.running_state = running
        ct.ephemeral_state = ephemeral
        ct.log_lines = []
      end
    end

    before do
      hook = stub_const('OsCtld::Hook', Class.new do
        def self.run(*); end
      end)
      dist_config = stub_const('OsCtld::DistConfig', Class.new do
        def self.run(*, **); end
      end)
      allow(hook).to receive(:run)
      allow(dist_config).to receive(:run)
      allow(OsCtld::Container::LifecycleExecutor).to receive(:acquire).and_return(true)
      allow(OsCtld::Container::LifecycleExecutor).to receive(:release)
      allow(OsCtld::ThreadReaper).to receive(:add)
      allow(Thread).to receive(:new) do |&block|
        block.call
        instance_double(Thread)
      end
    end

    it 'maps stop methods to the expected dist-config mode' do
      ct = build_stop_container
      command = described_class.new({ timeout: 10, method: 'kill' }, {})

      expect(command.execute(ct)).to eq(
        status: true,
        output: { lifecycle_state: 'stopped', run_id: 'run-1' }
      )
      expect(OsCtld::DistConfig).to have_received(:run).with(
        ct.get_run_conf,
        :stop,
        mode: :kill,
        message: nil,
        timeout: 10
      )
    end

    it 'switches shutdown_or_kill to kill for frozen containers' do
      ct = build_stop_container(state: :frozen)
      command = described_class.new({ timeout: 10, method: 'shutdown_or_kill' }, {})

      command.execute(ct)

      expect(OsCtld::DistConfig).to have_received(:run).with(
        ct.get_run_conf,
        :stop,
        mode: :kill,
        message: nil,
        timeout: 10
      )
    end

    it 'rejects pure shutdown for frozen containers' do
      ct = build_stop_container(state: :frozen)
      command = described_class.new({ timeout: 10, method: 'shutdown_or_fail' }, {})

      expect(command.execute(ct)).to eq(
        status: false,
        message: 'The container is frozen, unable to shutdown'
      )
    end

    it 'aborts when the pre-stop hook fails' do
      ct = build_stop_container
      command = described_class.new({ timeout: 10 }, {})
      hook = Class.new do
        def self.hook_name
          'pre_stop'
        end
      end.new
      allow(OsCtld::Hook).to receive(:run).and_raise(
        OsCtld::HookFailed.new(hook, '/hooks/pre-stop', 1)
      )

      expect(command.execute(ct)).to eq(
        status: false,
        message: 'hook pre_stop at /hooks/pre-stop exited with 1'
      )
    end

    it 'forces cleanup when user-runner shutdown fails' do
      ct = build_stop_container
      command = described_class.new({ timeout: 10 }, {})
      allow(OsCtld::DistConfig).to receive(:run)
        .and_raise(OsCtld::ContainerControl::UserRunnerError, 'runner failed')
      allow(command).to receive(:force_kill)
        .with(
          ct,
          'run-1',
          'effect-1',
          report_progress: false
        )
        .and_return(true)

      expect(command.execute(ct)).to eq(
        status: true,
        output: { lifecycle_state: 'stopped', run_id: 'run-1' }
      )
      expect(command).to have_received(:force_kill).with(
        ct,
        'run-1',
        'effect-1',
        report_progress: false
      )
    end

    it 'maps container-control errors to command failures' do
      ct = build_stop_container
      command = described_class.new({ timeout: 10 }, {})
      allow(OsCtld::DistConfig).to receive(:run)
        .and_raise(OsCtld::ContainerControl::Error, 'stop failed')

      expect(command.execute(ct)).to eq(
        status: false,
        message: 'stop failed'
      )
    end

    it 'waits for exact-generation finalization after issuing stop' do
      promise = double('exit_promise', wait: true)
      ct = build_stop_container(promise:)
      command = described_class.new({ timeout: 10 }, {})

      command.execute(ct)

      expect(ct.lifecycle.waited_run_id).to eq('run-1')
      expect(promise).not_to have_received(:wait)
    end

    it 'leaves ephemeral deletion to exact-generation finalization' do
      ct = build_stop_container(ephemeral: true)
      delete_class = stub_const('OsCtld::Commands::Container::Delete', Class.new)
      command = described_class.new({ timeout: 10 }, {})
      allow(command).to receive(:call_cmd!)

      expect(command.execute(ct)).to eq(
        status: true,
        output: { lifecycle_state: 'stopped', run_id: 'run-1' }
      )
      expect(command).not_to have_received(:call_cmd!).with(
        delete_class,
        anything
      )
    end

    it 'does not auto-delete ephemeral containers for indirect stops' do
      ct = build_stop_container(ephemeral: true)
      delete_class = stub_const('OsCtld::Commands::Container::Delete', Class.new)
      command = described_class.new({ timeout: 10 }, { indirect: true })
      allow(command).to receive(:call_cmd!)

      command.execute(ct)

      expect(command).not_to have_received(:call_cmd!).with(
        delete_class,
        anything
      )
    end

    it 'freezes, kills, thaws, and cleans up in order during force_kill' do
      recovery = Class.new do
        attr_reader :events

        def initialize(_ct)
          @events = []
        end

        def freeze_generation(run_id)
          events << [:freeze_generation, run_id]
        end

        def kill_generation(run_id)
          events << [:kill_generation, run_id]
        end

        def thaw_generation(run_id)
          events << [:thaw_generation, run_id]
        end

        def recover_state(run_id:)
          events << [:recover_state, run_id]
        end
      end.new(nil)
      recovery_class = stub_const('OsCtld::Container::Recovery', Class.new do
        def self.new(_ct); end
      end)
      allow(recovery_class).to receive(:new).and_return(recovery)
      ct = build_stop_container
      command = described_class.new({}, {})

      expect(command.send(:force_kill, ct, 'run-1', 'effect-1')).to be(true)
      expect(recovery.events).to eq(
        [
          [:freeze_generation, 'run-1'],
          [:kill_generation, 'run-1'],
          [:thaw_generation, 'run-1'],
          [:recover_state, 'run-1']
        ]
      )
    end
  end

  describe OsCtld::Commands::Container::Restart do
    it 'reboots through container-control when requested' do
      reboot = stub_const('OsCtld::ContainerControl::Commands::Reboot', Class.new do
        def self.run!(_ct); end
      end)
      allow(reboot).to receive(:run!)
      request = OsCtld::Container::Lifecycle::Request.new(action: :ready)
      lifecycle = double(request_control_reboot: request)
      ct = Struct.new(:pool, :lifecycle) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(Struct.new(:name).new('tank'), lifecycle)
      command = described_class.new({ reboot: true }, {})

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(reboot).to have_received(:run!).with(ct)
    end

    it 'waits for lifecycle admission before a direct reboot' do
      reboot = stub_const('OsCtld::ContainerControl::Commands::Reboot', Class.new do
        def self.run!(_ct); end
      end)
      allow(reboot).to receive(:run!)
      waiting = OsCtld::Container::Lifecycle::Request.new(
        action: :wait,
        revision: 10
      )
      ready = OsCtld::Container::Lifecycle::Request.new(action: :ready)
      lifecycle = double
      allow(lifecycle).to receive(:request_control_reboot)
        .and_return(waiting, ready)
      allow(lifecycle).to receive(:wait_for_change).with(10).and_return(true)
      ct = Struct.new(:pool, :lifecycle) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(Struct.new(:name).new('tank'), lifecycle)
      command = described_class.new({ reboot: true }, {})

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(lifecycle).to have_received(:wait_for_change).with(10)
      expect(reboot).to have_received(:run!).with(ct)
    end

    it 'rejects a direct reboot when lifecycle admission is blocked' do
      request = OsCtld::Container::Lifecycle::Request.new(
        action: :blocked,
        warning: 'container cgroup policy is tainted'
      )
      lifecycle = double(request_control_reboot: request)
      ct = Struct.new(:pool, :lifecycle) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(Struct.new(:name).new('tank'), lifecycle)
      command = described_class.new({ reboot: true }, {})

      expect { command.execute(ct) }.to raise_error(
        OsCtld::CommandFailed,
        'container cgroup policy is tainted'
      )
    end

    it 'retains direct reboot ownership when the reply is lost after delivery' do
      reboot = stub_const(
        'OsCtld::ContainerControl::Commands::Reboot',
        Class.new do
          def self.run!(_ct); end
        end
      )
      signal_delivered = false
      allow(reboot).to receive(:run!) do
        signal_delivered = true
        raise OsCtld::ContainerControl::Error, 'runner reply was lost'
      end
      request = OsCtld::Container::Lifecycle::Request.new(
        action: :ready,
        run_id: 'run-1',
        effect_id: 'effect-1'
      )
      lifecycle = double(
        request_control_reboot: request,
        record_control_reboot_error: true
      )
      ct = Struct.new(:pool, :lifecycle) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(Struct.new(:name).new('tank'), lifecycle)
      command = described_class.new({ reboot: true }, {})

      expect { command.execute(ct) }.to raise_error(
        OsCtld::CommandFailed,
        'runner reply was lost'
      )
      expect(signal_delivered).to be(true)
      expect(lifecycle).to have_received(:record_control_reboot_error).with(
        'run-1',
        'effect-1',
        'runner reply was lost'
      )
    end

    it 'stops and restarts the container with forwarded options' do
      stop_class = stub_const('OsCtld::Commands::Container::Stop', Class.new)
      start_class = stub_const('OsCtld::Commands::Container::Start', Class.new)
      request = OsCtld::Container::Lifecycle::Request.new(
        action: :stop,
        effect_id: 'intent-1'
      )
      lifecycle = double(request_restart: request)
      ct = Struct.new(:id, :pool, :lifecycle) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new('ct1', Struct.new(:name).new('tank'), lifecycle)
      command = described_class.new(
        { reboot: false, stop_timeout: 15, stop_method: 'kill', message: 'bye', wait: false },
        {}
      )
      allow(command).to receive(:call_cmd!).with(
        stop_class,
        pool: 'tank',
        id: 'ct1',
        timeout: 15,
        method: 'kill',
        message: 'bye',
        lifecycle_source: 'restart',
        lifecycle_intent_id: 'intent-1'
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        start_class,
        pool: 'tank',
        id: 'ct1',
        force: true,
        wait: false,
        lifecycle_source: 'restart',
        lifecycle_intent_id: 'intent-1'
      ).and_return(status: true, output: nil)

      expect(command.execute(ct)).to eq(status: true, output: nil)
    end
  end

  describe OsCtld::Commands::Container::Boot do
    def build_boot_container(pool:, run_conf:, rootfs: '/rootfs')
      mounts = Struct.new(:entries) do
        def find_at(path)
          entries[path]
        end
      end.new({})
      Struct.new(
        :id,
        :pool,
        :dataset,
        :distribution,
        :version,
        :arch,
        :vendor,
        :variant,
        :rootfs,
        :mounts,
        keyword_init: true
      ) do
        attr_accessor :running_state, :events, :new_run_conf_obj

        def running?
          running_state
        end

        def mount(force: false)
          events << [:mount, force]
        end

        def new_run_conf
          new_run_conf_obj
        end

        def set_next_run_conf(ctrc)
          events << [:set_next_run_conf, ctrc]
        end

        def manipulate(_holder, block:, &)
          events << :manipulate_enter
          yield
        ensure
          events << :manipulate_exit
        end
      end.new(
        id: 'ct1',
        pool:,
        dataset: 'tank/ct1',
        distribution: 'almalinux',
        version: '9',
        arch: 'x86_64',
        vendor: 'custom-vendor',
        variant: 'special',
        rootfs:,
        mounts:
      ).tap do |ct|
        ct.running_state = false
        ct.events = []
        ct.new_run_conf_obj = run_conf
      end
    end

    before do
      mount_entry = stub_const('OsCtld::Mount::Entry', Class.new do
        def initialize(*); end
      end)
      allow(mount_entry).to receive(:new).and_call_original
    end

    it 'rejects rootfs mount conflicts with persistent mounts' do
      pool = Struct.new(:name).new('tank')
      run_conf = double('RunConf')
      ct = build_boot_container(pool:, run_conf:)
      ct.mounts.entries['/mnt/root'] = Struct.new(:temp).new(false)
      command = described_class.new(
        { mount_root: '/mnt/root', type: 'image', path: '/tmp/image.tar' },
        {}
      )

      expect { command.execute(ct) }
        .to raise_error(OsCtld::CommandFailed, /unable to mount rootfs/)
    end

    it 'fills missing remote image attributes from the target container and starts queued boots after unlocking' do
      with_tmpdir do |tmpdir|
        image_path = File.join(tmpdir, 'image.tar')
        File.write(image_path, 'image')
        pool = Struct.new(:name).new('tank')
        run_conf = Struct.new do
          def boot_from(**opts)
            @boot_opts = opts
          end

          attr_reader :boot_opts
        end.new
        ct = build_boot_container(pool:, run_conf:)
        tmp_ds = instance_double(OsCtl::Lib::Zfs::Dataset, create!: nil)
        dataset_class = stub_const('OsCtl::Lib::Zfs::Dataset', Class.new do
          def self.new(*); end
        end)
        builder_class = stub_const('OsCtld::Container::Builder', Class.new do
          def self.new(*); end
        end)
        importer_class = stub_const('OsCtld::Container::Importer', Class.new do
          def self.new(*); end
        end)
        builder = instance_double(builder_class, shift_or_mount_dataset: nil, setup_ct_dir: nil, setup_rootfs: nil)
        importer = instance_double(
          importer_class,
          load_metadata: nil,
          get_container_config: {},
          import_root_dataset: nil
        )
        gc = stub_const('OsCtld::GarbageCollector', Class.new do
          def self.add_container_run_dataset(*); end
        end)
        allow(dataset_class).to receive(:new).and_return(tmp_ds)
        allow(builder_class).to receive(:new).and_return(builder)
        allow(importer_class).to receive(:new).and_return(importer)
        allow(gc).to receive(:add_container_run_dataset)
        command = described_class.new(
          {
            type: 'remote',
            image: {},
            queue: true,
            wait: false,
            priority: 3
          },
          {}
        )
        allow(command).to receive(:with_image_path) do |pool_arg, type:, path:, image:, &block|
          expect(pool_arg).to eq(pool)
          expect(type).to eq('remote')
          expect(path).to be_nil
          expect(image).to eq(
            distribution: 'almalinux',
            version: '9',
            arch: 'x86_64',
            vendor: 'custom-vendor',
            variant: 'special'
          )
          block.call(image_path)
        end
        allow(command).to receive(:call_cmd!).with(
          OsCtld::Commands::Container::Stop,
          pool: 'tank',
          id: 'ct1'
        ).and_return(status: true, output: nil)
        allow(command).to receive(:start_ct) do |_, _|
          ct.events << [:start_ct, ct.events.last != :manipulate_exit]
          { status: true, output: nil }
        end

        expect(command.execute(ct)).to eq(status: true, output: nil)
        expect(gc).to have_received(:add_container_run_dataset).with(run_conf, tmp_ds)
        expect(ct.events).to include([:set_next_run_conf, run_conf])
        expect(ct.events.last).to eq([:start_ct, false])
      end
    end
  end

  describe OsCtld::Commands::Container::Delete do
    let(:stop_class) { stub_const('OsCtld::Commands::Container::Stop', Class.new) }
    let(:user_delete_class) { stub_const('OsCtld::Commands::User::Delete', Class.new) }
    let(:lxc_usernet_class) { stub_const('OsCtld::Commands::User::LxcUsernet', Class.new) }

    def build_delete_container(root:)
      trash_bin = Struct.new do
        def prune; end
      end.new
      autostart_plan = Struct.new do
        attr_reader :cleared

        def clear_ct(ct)
          @cleared = ct
        end
      end.new
      pool = Struct.new(:name, :trash_bin, :autostart_plan).new('tank', trash_bin, autostart_plan)
      shared_dir = Struct.new do
        attr_reader :removed

        def remove
          @removed = true
        end
      end.new
      mounts = Struct.new(:shared_dir).new(shared_dir)
      send_log = Struct.new(:opts).new(Struct.new(:key_name).new('tx'))
      user = Struct.new(:standalone, :pool, :name) do
        def has_containers?
          false
        end
      end.new(false, pool, 'alice')
      group_dir = File.join(root, 'group')
      FileUtils.mkdir_p(group_dir)
      lxc_dir = File.join(root, 'lxc')
      hook_dir = File.join(root, 'hooks')
      FileUtils.mkdir_p(lxc_dir)
      FileUtils.mkdir_p(hook_dir)
      config_path = File.join(root, 'ct.yml')
      log_path = File.join(root, 'ct.log')
      File.write(config_path, 'cfg')
      File.write(log_path, 'log')
      Struct.new(
        :id,
        :pool,
        :mounts,
        :send_log,
        :dataset,
        :lxc_dir,
        :user_hook_script_dir,
        :log_path,
        :config_path,
        :group,
        :user,
        :base_cgroup_path,
        :lifecycle,
        keyword_init: true
      ) do
        attr_accessor :clear_start_menu_calls, :running_state

        def running?
          running_state
        end

        def clear_start_menu
          self.clear_start_menu_calls += 1
        end

        def log(*); end

        def manipulate(_holder, block:, &)
          yield
        end

        def exclusively(&block)
          block.call
        end
      end.new(
        id: 'ct1',
        pool:,
        mounts:,
        send_log:,
        dataset: 'tank/ct1',
        lxc_dir:,
        user_hook_script_dir: hook_dir,
        log_path:,
        config_path:,
        group: Struct.new(:userdir_path) do
          def has_containers?(_user)
            false
          end

          def full_cgroup_path(_user)
            '/sys/fs/cgroup/osctl/user.alice'
          end

          def userdir(_user)
            userdir_path
          end
        end.new(group_dir),
        user:,
        base_cgroup_path: '/sys/fs/cgroup/osctl/ct.ct1',
        lifecycle: double(residuals: [], runtime_generations: [])
      ).tap do |ct|
        ct.clear_start_menu_calls = 0
        ct.running_state = false
      end
    end

    before do
      build_db_containers
      send_receive = stub_const('OsCtld::SendReceive', Class.new do
        def self.stopped_using_key(*); end
      end)
      console = stub_const('OsCtld::Console', Class.new do
        def self.remove(*); end
      end)
      trash = stub_const('OsCtld::TrashBin', Class.new do
        def self.add_dataset(*); end
      end)
      monitor = stub_const('OsCtld::Monitor::Master', Class.new do
        def self.demonitor(*); end
      end)
      cgroup = stub_const('OsCtld::CGroup', Class.new do
        def self.rmpath_all(*); end
      end)
      apparmor = stub_const('OsCtld::AppArmor', Class.new do
        def self.enabled?
          false
        end
      end)
      allow(send_receive).to receive(:stopped_using_key)
      allow(console).to receive(:remove)
      allow(trash).to receive(:add_dataset)
      allow(monitor).to receive(:demonitor)
      allow(cgroup).to receive(:rmpath_all)
      allow(apparmor).to receive(:enabled?).and_return(false)
      allow(OsCtld::DB::Containers).to receive(:remove)
    end

    def stub_successful_delete_commands(command, message: nil)
      allow(command).to receive(:call_cmd!).with(
        stop_class,
        pool: 'tank',
        id: 'ct1',
        manipulation_lock: nil,
        progress: nil,
        message:
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        user_delete_class,
        pool: 'tank',
        name: 'alice'
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd).with(lxc_usernet_class).and_return(status: true, output: nil)
      allow(command).to receive(:syscmd)
    end

    it 'rejects running containers unless force is set' do
      with_tmpdir do |tmpdir|
        ct = build_delete_container(root: tmpdir)
        ct.running_state = true

        expect { described_class.new({}, {}).execute(ct) }
          .to raise_error(OsCtld::CommandFailed, 'the container is running')
      end
    end

    it 'stops, unregisters, cleans up, and prunes when requested' do
      with_tmpdir do |tmpdir|
        ct = build_delete_container(root: tmpdir)
        command = described_class.new({ prune: true, message: 'bye' }, {})
        allow(ct.pool.trash_bin).to receive(:prune)
        stub_successful_delete_commands(command, message: 'bye')

        expect(command.execute(ct)).to eq(status: true, output: nil)
        expect(OsCtld::SendReceive).to have_received(:stopped_using_key).with(ct.pool, 'tx')
        expect(OsCtld::Console).to have_received(:remove).with(ct)
        expect(OsCtld::TrashBin).to have_received(:add_dataset).with(ct.pool, 'tank/ct1')
        expect(OsCtld::Monitor::Master).to have_received(:demonitor).with(ct)
        expect(OsCtld::DB::Containers).to have_received(:remove).with(ct)
        expect(OsCtld::CGroup).to have_received(:rmpath_all).with('/sys/fs/cgroup/osctl/user.alice')
        expect(ct.clear_start_menu_calls).to eq(1)
        expect(ct.mounts.shared_dir.removed).to be(true)
        expect(ct.pool.autostart_plan.cleared).to equal(ct)
        expect(ct.pool.trash_bin).to have_received(:prune)
      end
    end

    it 'does not delete storage when stop quarantines a residual generation' do
      with_tmpdir do |tmpdir|
        ct = build_delete_container(root: tmpdir)
        run_id = OsCtld::Container::RunId.new(
          pool_name: 'tank',
          container_id: 'ct1'
        )
        allow(ct.lifecycle).to receive(:runtime_generations).and_return(
          [{ 'id' => run_id.dump, 'role' => 'residual' }]
        )
        command = described_class.new({ force: true }, {})
        allow(command).to receive(:call_cmd!).with(
          stop_class,
          pool: 'tank',
          id: 'ct1',
          manipulation_lock: nil,
          progress: nil,
          message: nil
        ).and_return(
          status: true,
          output: {
            lifecycle_state: 'quarantined',
            run_id: run_id.to_s
          }
        )

        expect do
          command.execute(ct)
        end.to raise_error(
          OsCtld::CommandFailed,
          /container deletion is blocked.*residual/
        )
        expect(OsCtld::TrashBin).not_to have_received(:add_dataset)
        expect(OsCtld::DB::Containers).not_to have_received(:remove)
      end
    end

    it 'unregisters the container when its dataset is already missing' do
      with_tmpdir do |tmpdir|
        ct = build_delete_container(root: tmpdir)
        command = described_class.new({}, {})
        stub_successful_delete_commands(command)
        allow(OsCtld::TrashBin).to receive(:add_dataset).and_raise(
          OsCtld::SystemCommandFailed.new(
            'zfs list tank/ct1',
            1,
            "cannot open 'tank/ct1': dataset does not exist\n"
          )
        )

        expect(command.execute(ct)).to eq(status: true, output: nil)
        expect(OsCtld::DB::Containers).to have_received(:remove).with(ct)
        expect(OsCtld::Monitor::Master).to have_received(:demonitor).with(ct)
      end
    end
  end

  describe OsCtld::Commands::Container::Freeze do
    it 'returns an error when the container cannot be found' do
      db = build_db_containers
      allow(db).to receive(:find).with('ct1', 'tank').and_return(nil)

      expect(described_class.run(id: 'ct1', pool: 'tank')).to eq(
        status: false,
        message: 'container not found'
      )
    end

    it 'delegates freezing to container-control only when needed' do
      db = build_db_containers
      freeze_cmd = stub_const('OsCtld::ContainerControl::Commands::Freeze', Class.new do
        def self.run!(_ct); end
      end)
      ct = Struct.new(:state) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(:running)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(freeze_cmd).to receive(:run!)

      expect(described_class.run(id: 'ct1', pool: 'tank')).to eq(status: true, output: nil)
      expect(freeze_cmd).to have_received(:run!).with(ct)
    end
  end

  describe OsCtld::Commands::Container::Unfreeze do
    it 'returns ok without delegating when the container is already running' do
      db = build_db_containers
      thaw_cmd = stub_const('OsCtld::ContainerControl::Commands::Unfreeze', Class.new do
        def self.run!(_ct); end
      end)
      ct = Struct.new(:state) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(:running)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(thaw_cmd).to receive(:run!)

      expect(described_class.run(id: 'ct1', pool: 'tank')).to eq(status: true, output: nil)
      expect(thaw_cmd).not_to have_received(:run!)
    end
  end

  describe OsCtld::Commands::Container::Reconfigure do
    it 'reconfigures the resolved container' do
      db = build_db_containers
      lxc_config = Struct.new do
        attr_reader :configured

        def configure
          @configured = true
        end
      end.new
      ct = Struct.new(:lxc_config) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(lxc_config)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect(described_class.run(id: 'ct1', pool: 'tank')).to eq(status: true, output: nil)
      expect(lxc_config.configured).to be(true)
    end
  end
end

# rubocop:enable Lint/ConstantDefinitionInBlock, Lint/StructNewOverride, RSpec/DescribeClass, RSpec/LeakyConstantDeclaration, RSpec/VerifiedDoubles
