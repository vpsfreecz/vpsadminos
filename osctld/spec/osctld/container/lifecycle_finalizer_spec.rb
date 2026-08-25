# frozen_string_literal: true

require 'osctld/container/lifecycle_finalizer'
require 'osctld/utils/switch_user'
require 'osctld/container'
require 'osctld/container/lifecycle'
require 'osctld/container/lxc_config'
require 'osctld/container/run_configuration'
require 'osctld/container/run_id'
require 'osctld/config'

RSpec.describe OsCtld::Container::LifecycleFinalizer do
  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
    allow(OsCtld::ThreadReaper).to receive(:add)
    stub_const('OsCtld::Commands::Container::Delete', Class.new do
      def self.run(*); end
    end)
    stub_const('OsCtld::CpuScheduler', Class.new do
      def self.unschedule_ct(_ct); end
    end)
    allow(OsCtld::CpuScheduler).to receive(:unschedule_ct)
  end

  it 'tracks lxc-start when the wrapper identity was not persisted' do
    alive_checks = 0
    manager = instance_double(OsCtld::ProcessIdentity)
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      run: {
        'wrapper' => nil,
        'lxc_start' => nil,
        'legacy_managers' => [{ 'pid' => 123 }]
      },
      observe_wrapper_gone: nil,
      active_run_id: nil
    )
    ct = instance_double(OsCtld::Container, lifecycle:)
    run_conf = instance_double(
      OsCtld::Container::RunConfiguration,
      run_id: 'run-1'
    )

    allow(manager).to receive(:alive?) do
      alive_checks += 1
      alive_checks == 1
    end
    allow(OsCtld::ProcessIdentity).to receive(:load).and_return(manager)
    daemon_class = stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    daemon = Class.new do
      def stopping? = false
    end.new
    allow(daemon_class).to receive(:get).and_return(daemon)

    thread = described_class.watch_wrapper(ct, run_conf)
    thread.join(1)

    expect(thread).not_to be_alive
    expect(alive_checks).to be >= 2
    expect(lifecycle).to have_received(:observe_wrapper_gone).with('run-1')
  end

  it 'defers wrapper recovery when restart preparation already closed admission' do
    alive_checks = 0
    manager = instance_double(OsCtld::ProcessIdentity)
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      run: {
        'wrapper' => { 'pid' => 123 },
        'lxc_start' => nil,
        'legacy_managers' => [],
        'post_stop' => false
      },
      observe_wrapper_gone: nil,
      active_run_id: 'run-1'
    )
    ct = instance_double(OsCtld::Container, lifecycle:, ident: 'tank:ct1')
    run_conf = instance_double(
      OsCtld::Container::RunConfiguration,
      run_id: 'run-1'
    )
    recovery = instance_double(OsCtld::Container::Recovery)

    allow(manager).to receive(:alive?) do
      alive_checks += 1
      alive_checks == 1
    end
    allow(OsCtld::ProcessIdentity).to receive(:load).and_return(manager)
    allow(OsCtld::Container::Recovery).to receive(:new)
      .with(ct)
      .and_return(recovery)
    allow(recovery).to receive(:recover_state)
      .with(run_id: 'run-1')
      .and_raise(OsCtld::CommandFailed, 'daemon phase prepared')
    daemon_class = stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    daemon = Class.new do
      def stopping? = false
    end.new
    allow(daemon_class).to receive(:get).and_return(daemon)

    thread = described_class.watch_wrapper(ct, run_conf)
    thread.join(1)

    expect(thread).not_to be_alive
    expect(recovery).to have_received(:recover_state).with(run_id: 'run-1')
  end

  it 'retries restart reconciliation after a persisted hook process exits' do
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      run: {
        'recovery' => nil,
        'processes' => {
          'process-1' => {
            'identity' => { 'pid' => 123, 'start_time_ticks' => 456 }
          }
        }
      },
      active_run_id: 'run-1'
    )
    ct = instance_double(OsCtld::Container, lifecycle:)
    run_conf = instance_double(
      OsCtld::Container::RunConfiguration,
      run_id: 'run-1'
    )
    recovery = instance_double(OsCtld::Container::Recovery)
    calls = 0

    allow(recovery).to receive(:recover_state) do
      calls += 1
      raise OsCtld::Container::Recovery::Busy if calls == 1

      { state: :stopped }
    end
    allow(OsCtld::Container::Recovery).to receive(:new)
      .with(ct)
      .and_return(recovery)
    daemon_class = stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    daemon = Class.new do
      def stopping? = false
    end.new
    allow(daemon_class).to receive(:get).and_return(daemon)

    thread = described_class.watch_reconciliation(ct, run_conf)
    thread.join(1)

    expect(thread).not_to be_alive
    expect(recovery).to have_received(:recover_state)
      .with(run_id: 'run-1').twice
  end

  it 'does not continue cleanup when recovery supersedes an on-stop hook' do
    current = true
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      run: { 'on_stop_hook_started' => false },
      claim_finalizer_hook: true,
      complete_finalizer_hook: false
    )
    run_conf = instance_double(
      OsCtld::Container::RunConfiguration,
      run_id: 'run-1'
    )
    ct = instance_double(OsCtld::Container, lifecycle:)
    finalizer = described_class.new(ct, run_conf, 'effect-1')

    allow(lifecycle).to receive(:set_effect_worker)
    allow(lifecycle).to receive(:effect_worker_exited)
    allow(lifecycle).to receive(:effect_current?) { current }
    allow(OsCtld::Hook).to receive(:run) { current = false }

    finalizer.execute

    expect(lifecycle).to have_received(:complete_finalizer_hook).with(
      'run-1',
      'effect-1',
      :on_stop,
      error: nil
    )
    expect(OsCtld::CpuScheduler).not_to have_received(:unschedule_ct)
  end

  it 'retains scheduler accounting when generation cleanup is superseded' do
    current = true
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      other_runtime_generation?: false
    )
    run_conf = instance_double(
      OsCtld::Container::RunConfiguration,
      run_id: 'run-1',
      aborted?: false
    )
    ct = instance_double(OsCtld::Container, lifecycle:)
    finalizer = described_class.new(ct, run_conf, 'effect-1')

    allow(lifecycle).to receive(:set_effect_worker)
    allow(lifecycle).to receive(:effect_worker_exited)
    allow(lifecycle).to receive(:effect_current?) { current }
    allow(finalizer).to receive(:run_finalizer_hook)
    allow(finalizer).to receive(:prune_mounts)
    allow(finalizer).to receive(:update_hints)
    allow(finalizer).to receive(:cleanup_cgroups) { current = false }
    allow(finalizer).to receive(:cleanup_apparmor)

    finalizer.execute

    expect(finalizer).to have_received(:update_hints)
    expect(OsCtld::CpuScheduler).not_to have_received(:unschedule_ct)
    expect(finalizer).not_to have_received(:cleanup_apparmor)
  end

  it 'persists a cleanup failure instead of leaving an ownerless effect' do
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      other_runtime_generation?: false
    )
    run_conf = instance_double(
      OsCtld::Container::RunConfiguration,
      run_id: 'run-1',
      aborted?: false
    )
    ct = instance_double(OsCtld::Container, lifecycle:)
    finalizer = described_class.new(ct, run_conf, 'effect-1')

    allow(lifecycle).to receive(:set_effect_worker)
    allow(lifecycle).to receive(:effect_worker_exited)
    allow(lifecycle).to receive(:effect_current?).and_return(true)
    allow(lifecycle).to receive(:fail_cleanup)
    allow(finalizer).to receive(:run_finalizer_hook)
    allow(finalizer).to receive(:prune_mounts)
    allow(finalizer).to receive(:update_hints)
    allow(finalizer).to receive(:cleanup_cgroups)
    allow(OsCtld::CpuScheduler).to receive(:unschedule_ct).and_raise('broken')

    finalizer.execute

    expect(lifecycle).to have_received(:fail_cleanup).with(
      'run-1',
      'effect-1',
      'broken'
    )
  end

  it 'skips dataset writeout when the runtime rootfs is unavailable' do
    config = instance_double(
      OsCtld::Config,
      writeout_dirtied_pages?: true
    )
    daemon_class = stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
      def config; end
    end)
    daemon = instance_double(daemon_class, config:)
    allow(daemon_class).to receive(:get).and_return(daemon)
    run_conf = instance_double(
      OsCtld::Container::RunConfiguration,
      destroy_dataset_on_stop?: false,
      rootfs: nil
    )
    ct = instance_double(
      OsCtld::Container,
      lifecycle: instance_double(OsCtld::Container::Lifecycle),
      ephemeral?: false,
      unmount: nil,
      mount: nil
    )
    finalizer = described_class.new(ct, run_conf, 'effect-1')

    expect(finalizer.send(:writeout_dataset)).to be_nil
    expect(ct).not_to have_received(:unmount)
    expect(ct).not_to have_received(:mount)
  end

  it 'does not commit cleanup after an exit event supersedes its effect' do
    current = true
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      other_runtime_generation?: false
    )
    pool = Struct.new(:name).new('tank')
    run_id = instance_double(
      OsCtld::Container::RunId,
      to_s: 'tank:ct1:run-1'
    )
    run_conf = instance_double(
      OsCtld::Container::RunConfiguration,
      run_id:,
      aborted?: false,
      destroy_dataset_on_stop?: false,
      reboot?: false
    )
    ct = instance_double(
      OsCtld::Container,
      lifecycle:,
      pool:,
      id: 'ct1'
    )
    finalizer = described_class.new(ct, run_conf, 'effect-1')

    allow(lifecycle).to receive(:set_effect_worker)
    allow(lifecycle).to receive(:effect_worker_exited)
    allow(lifecycle).to receive(:effect_current?) { current }
    allow(lifecycle).to receive(:complete_run)
    allow(lifecycle).to receive_messages(
      execution_run?: false,
      exit_event: :halt
    )
    allow(finalizer).to receive(:run_finalizer_hook)
    allow(finalizer).to receive(:prune_mounts)
    allow(finalizer).to receive(:update_hints)
    allow(finalizer).to receive(:cleanup_cgroups)
    allow(finalizer).to receive(:cleanup_apparmor)
    allow(finalizer).to receive(:writeout_dataset)
    allow(OsCtld::Eventd).to receive(:report) { current = false }
    allow(run_conf).to receive(:fulfil_exit)

    finalizer.execute

    expect(run_conf).not_to have_received(:fulfil_exit)
    expect(lifecycle).not_to have_received(:complete_run)
  end

  it 'does not report a container exit for an aborted start' do
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      set_effect_worker: true,
      effect_worker_exited: true,
      effect_current?: true,
      complete_run: [true, nil],
      execution_run?: false,
      exit_event: nil,
      other_runtime_generation?: false
    )
    lxc_config = instance_double(
      OsCtld::Container::LxcConfig,
      run_config_path: '/run/lxc/config.run-1',
      remove_run_hooks: nil
    )
    run_conf = instance_double(
      OsCtld::Container::RunConfiguration,
      run_id: 'run-1',
      aborted?: true,
      destroy_dataset_on_stop?: false,
      fulfil_exit: nil,
      destroy: nil
    )
    ct = instance_double(
      OsCtld::Container,
      lifecycle:,
      lxc_config:,
      ephemeral?: false,
      forget_past_run_conf: true
    )
    finalizer = described_class.new(ct, run_conf, 'effect-1')

    allow(finalizer).to receive(:run_finalizer_hook)
    allow(finalizer).to receive(:prune_mounts)
    allow(finalizer).to receive(:update_hints)
    allow(finalizer).to receive(:cleanup_cgroups)
    allow(finalizer).to receive(:cleanup_apparmor)
    allow(finalizer).to receive(:writeout_dataset)
    allow(OsCtld::Eventd).to receive(:report)
    allow(File).to receive(:unlink).with('/run/lxc/config.run-1')

    finalizer.execute

    expect(OsCtld::Eventd).not_to have_received(:report)
    expect(run_conf).to have_received(:fulfil_exit)
    expect(lifecycle).to have_received(:complete_run).with(
      run_conf.run_id,
      'effect-1'
    )
  end

  it 'deletes an ephemeral container only after its exact run is complete' do
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      set_effect_worker: true,
      effect_worker_exited: true,
      effect_current?: true,
      complete_run: [true, nil],
      residuals: [],
      execution_run?: false,
      exit_event: :halt,
      other_runtime_generation?: false
    )
    pool = Struct.new(:name).new('tank')
    lxc_config = instance_double(
      OsCtld::Container::LxcConfig,
      run_config_path: '/run/lxc/config.run-1',
      remove_run_hooks: nil
    )
    run_id = instance_double(
      OsCtld::Container::RunId,
      to_s: 'tank:ct1:run-1'
    )
    run_conf = instance_double(
      OsCtld::Container::RunConfiguration,
      run_id:,
      aborted?: false,
      destroy_dataset_on_stop?: false,
      reboot?: false,
      fulfil_exit: nil,
      destroy: nil
    )
    ct = instance_double(
      OsCtld::Container,
      lifecycle:,
      pool:,
      id: 'ct1',
      lxc_config:,
      ephemeral?: true,
      forget_past_run_conf: true
    )
    finalizer = described_class.new(ct, run_conf, 'effect-1')

    allow(finalizer).to receive(:run_finalizer_hook)
    allow(finalizer).to receive(:prune_mounts)
    allow(finalizer).to receive(:update_hints)
    allow(finalizer).to receive(:cleanup_cgroups)
    allow(finalizer).to receive(:cleanup_apparmor)
    allow(finalizer).to receive(:writeout_dataset)
    allow(OsCtld::Eventd).to receive(:report)
    allow(File).to receive(:unlink).with('/run/lxc/config.run-1')
    allow(OsCtld::Commands::Container::Delete).to receive(:run)

    finalizer.execute

    expect(lifecycle).to have_received(:complete_run).with(run_conf.run_id, 'effect-1')
    expect(lxc_config).to have_received(:remove_run_hooks).with(run_conf)
    expect(run_conf).to have_received(:destroy)
    expect(OsCtld::Commands::Container::Delete).to have_received(:run).with(
      pool: 'tank',
      id: 'ct1',
      force: true,
      manipulation_lock: 'wait'
    )
  end
end
