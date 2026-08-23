# frozen_string_literal: true

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles

require 'osctld/container/recovery'
require 'osctld/container/lifecycle'
require 'osctld/container/run_id'
require 'osctld/container_control/commands/state'
require 'osctld/eventd'

RSpec.describe OsCtld::Container::Recovery do
  let(:pool) { FakeObjects::FakePool.new(name: 'tank') }
  let(:route) { double(addr: double(to_string: '10.0.0.1/32')) }
  let(:routes) { double }
  let(:netif) { double(type: :routed, routes: routes, veth: 'veth0') }
  let(:ct) do
    double(
      pool: pool,
      id: 'ct1',
      ident: 'tank:ct1',
      netifs: [netif]
    )
  end
  let(:recovery) { described_class.new(ct) }

  before do
    stub_daemon
    stub_const(
      'OsCtld::DB::Containers',
      Class.new do
        def self.get; end
      end
    )
    allow(OsCtld::Container::Recovery::RouteList).to receive(:new).and_return(
      double(veth_of: 'veth0')
    )
    allow(recovery).to receive(:syscmd)
    allow(recovery).to receive(:log)
    allow(routes).to receive(:each_version) do |_ip_v, &block|
      block.call(route)
    end
  end

  it 'removes stale veths that only the recovered container references' do
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct])

    yielded = []
    recovery.cleanup_netifs do |veth, found_routes|
      yielded << [veth, found_routes]
    end

    expect(yielded).to eq([['veth0', [route, route]]])
    expect(recovery).to have_received(:syscmd).with('ip link delete veth0')
  end

  it 'keeps veths that another container still references' do
    other_netif = double(veth: 'veth0')
    other_ct = double(netifs: [other_netif], ident: 'tank:ct2')
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct, other_ct])

    recovery.cleanup_netifs

    expect(recovery).not_to have_received(:syscmd).with('ip link delete veth0')
  end

  it 'recognizes a replacement intent that survived a daemon restart' do
    lifecycle = double(
      desired_state: :running,
      current_intent_id: 'replacement-intent'
    )
    allow(ct).to receive(:lifecycle).and_return(lifecycle)

    expect(
      recovery.send(
        :replacement_requested?,
        'launch_intent_id' => 'original-intent'
      )
    ).to be(true)
  end

  it 'removes host-effect descendants when cleaning an adopted legacy run' do
    run_id = OsCtld::Container::RunId.new(
      pool_name: 'tank',
      container_id: 'ct1',
      key: 'a' * 32
    )
    resources = {
      'cgroup_root' => '/osctl/ct.ct1',
      'host_effects' => '/osctl/ct.ct1/host-effects',
      'lxc_payload' => '/osctl/ct.ct1/user-owned/lxc.payload.ct1',
      'lxc_monitor' => '/osctl/ct.ct1/user-owned/lxc.monitor.ct1',
      'lxc_pivot' => '/osctl/ct.ct1/user-owned/lxc.pivot.ct1'
    }
    run = { 'id' => run_id.dump, 'resources' => resources }
    lifecycle = double(
      runs: { run_id.to_s => run },
      active_run: run,
      residuals: []
    )
    allow(ct).to receive_messages(
      lifecycle:,
      base_cgroup_path: '/osctl/ct.ct1'
    )
    allow(OsCtld::CGroup).to receive(:rmpath_all)

    recovery.cleanup_generation(run_id)

    expect(OsCtld::CGroup).to have_received(:rmpath_all)
      .with('/osctl/ct.ct1/host-effects')
    expect(OsCtld::CGroup).to have_received(:rmpath_all).exactly(4).times
  end

  it 'publishes unclaimed running effects during state recovery' do
    run_id = OsCtld::Container::RunId.new(
      pool_name: 'tank',
      container_id: 'ct1',
      key: 'b' * 32
    )
    run = {
      'id' => run_id.dump,
      'role' => 'active',
      'phase' => 'running',
      'launch_intent_id' => 'intent-1'
    }
    lifecycle = double(
      runs: { run_id.to_s => run },
      active_run: run,
      active_run_id: run_id,
      begin_reconciliation: 'reconciliation-1',
      supersede_stale_effect: nil,
      clear_stale_observer: true,
      run: run,
      commit_reconciliation: true,
      observe_state: true,
      desired_state: :running,
      current_intent_id: 'intent-1',
      claim_reconciliation_state_effects: true,
      complete_running_effects: true,
      finish_reconciliation: false,
      revision: 12
    )
    allow(ct).to receive_messages(
      lifecycle:,
      state: :running,
      run_conf: nil,
      get_past_run_conf: nil
    )
    allow(ct).to receive(:state=)
    allow(ct).to receive(:observe_run_state).and_return(true)
    allow(OsCtld::ContainerControl::Commands::State).to receive(:run!)
      .with(ct)
      .and_return(double(state: :running, init_pid: 5678))
    allow(OsCtld::Eventd).to receive(:report)
    allow(OsCtld::Hook).to receive(:run)
    ct.pool.define_singleton_method(:fulfil_autostart) { |_ct| nil }
    ct.pool.define_singleton_method(:fulfil_reboot) { |_ct| nil }
    allow(ct.pool).to receive(:fulfil_autostart)
    allow(ct.pool).to receive(:fulfil_reboot)

    result = recovery.recover_state(run_id: run_id)

    expect(result).to include(state: :running, run_id: run_id.to_s)
    expect(OsCtld::Eventd).to have_received(:report).with(
      :state,
      pool: 'tank',
      id: 'ct1',
      state: :running
    )
    expect(OsCtld::Hook).to have_received(:run)
      .with(ct, :post_start, init_pid: 5678)
    expect(lifecycle).to have_received(:complete_running_effects).with(
      run_id,
      'reconciliation-1',
      error: nil
    )
    expect(ct).to have_received(:observe_run_state).with(
      run_id,
      :running,
      init_pid: 5678
    )
    expect(ct.pool).to have_received(:fulfil_autostart).with(ct)
    expect(ct.pool).to have_received(:fulfil_reboot).with(ct)
  end

  it 'yields state recovery before mutation when an exact callback arrived' do
    run_id = OsCtld::Container::RunId.new(
      pool_name: 'tank',
      container_id: 'ct1',
      key: 'c' * 32
    )
    run = {
      'id' => run_id.dump,
      'role' => 'active',
      'phase' => 'running',
      'launch_intent_id' => 'intent-1'
    }
    lifecycle = double(
      runs: { run_id.to_s => run },
      active_run: run,
      active_run_id: run_id,
      begin_reconciliation: 'reconciliation-1',
      supersede_stale_effect: nil,
      clear_stale_observer: true,
      run: run,
      commit_reconciliation: false,
      finish_reconciliation: false,
      revision: 13
    )
    allow(lifecycle).to receive(:observe_state)
    allow(ct).to receive_messages(
      lifecycle:,
      state: :running
    )
    allow(ct).to receive(:state=)
    allow(OsCtld::ContainerControl::Commands::State).to receive(:run!)
      .with(ct)
      .and_return(double(state: :stopped, init_pid: nil))

    result = recovery.recover_state(run_id: run_id)

    expect(result).to include(
      state: :stopped,
      run_id: run_id.to_s,
      yielded_to_callback: true
    )
    expect(ct).not_to have_received(:state=)
    expect(lifecycle).not_to have_received(:observe_state)
    expect(lifecycle).to have_received(:finish_reconciliation).with(
      run_id,
      'reconciliation-1'
    )
  end

  it 'preserves an existing error state during LXC reconciliation' do
    run_id = OsCtld::Container::RunId.new(
      pool_name: 'tank',
      container_id: 'ct1',
      key: 'e' * 32
    )
    run = {
      'id' => run_id.dump,
      'role' => 'active',
      'phase' => 'running',
      'launch_intent_id' => 'intent-1'
    }
    lifecycle = double(
      runs: { run_id.to_s => run },
      active_run: run,
      active_run_id: run_id,
      begin_reconciliation: 'reconciliation-1',
      supersede_stale_effect: nil,
      clear_stale_observer: true,
      run:,
      commit_reconciliation: true,
      observe_state: true,
      desired_state: :running,
      current_intent_id: 'intent-1',
      finish_reconciliation: false,
      revision: 14
    )
    allow(ct).to receive_messages(
      lifecycle:,
      state: :error,
      run_conf: nil,
      get_past_run_conf: nil,
      observe_run_state: false
    )
    allow(ct).to receive(:state=)
    allow(OsCtld::ContainerControl::Commands::State).to receive(:run!)
      .with(ct)
      .and_return(double(state: :running, init_pid: 5678))
    allow(OsCtld::Eventd).to receive(:report)
    allow(OsCtld::Hook).to receive(:run)

    result = recovery.recover_state(run_id:)

    expect(result).to include(state: :error, run_id: run_id.to_s)
    expect(ct).not_to have_received(:state=)
    expect(OsCtld::Hook).not_to have_received(:run)
    expect(OsCtld::Eventd).not_to have_received(:report).with(
      :state,
      hash_including(state: :running)
    )
  end

  it 'keeps a transient execution logically stopped after daemon restart' do
    run_id = OsCtld::Container::RunId.new(
      pool_name: 'tank',
      container_id: 'ct1',
      key: 'f' * 32
    )
    run = {
      'id' => run_id.dump,
      'role' => 'active',
      'kind' => 'execution',
      'phase' => 'running',
      'launch_intent_id' => nil
    }
    lifecycle = double(
      runs: { run_id.to_s => run },
      active_run: run,
      active_run_id: run_id,
      begin_reconciliation: 'reconciliation-1',
      supersede_stale_effect: nil,
      clear_stale_observer: true,
      run:,
      commit_reconciliation: true,
      observe_state: true,
      desired_state: :stopped,
      current_intent_id: nil,
      finish_reconciliation: false,
      revision: 15
    )
    logical_state = :running
    allow(ct).to receive_messages(
      lifecycle:,
      run_conf: nil,
      get_past_run_conf: nil
    )
    allow(ct).to receive(:state) { logical_state }
    allow(ct).to receive(:state=) { |value| logical_state = value }
    allow(OsCtld::ContainerControl::Commands::State).to receive(:run!)
      .with(ct)
      .and_return(double(state: :running, init_pid: 5678))
    allow(OsCtld::Eventd).to receive(:report)
    allow(OsCtld::Hook).to receive(:run)
    allow(recovery).to receive(:run_reconciliation_followup)

    result = recovery.recover_state(run_id:)

    expect(result).to include(state: :stopped, run_id: run_id.to_s)
    expect(ct).to have_received(:state=).with(:stopped)
    expect(OsCtld::Hook).not_to have_received(:run)
    expect(recovery).to have_received(:run_reconciliation_followup).with(
      [:stop, nil]
    )
  end

  it 'does not publish an error when a failed state query has to yield' do
    run_id = OsCtld::Container::RunId.new(
      pool_name: 'tank',
      container_id: 'ct1',
      key: 'd' * 32
    )
    run = {
      'id' => run_id.dump,
      'role' => 'active',
      'phase' => 'running'
    }
    lifecycle = double(
      runs: { run_id.to_s => run },
      active_run: run,
      active_run_id: run_id,
      begin_reconciliation: 'reconciliation-1',
      supersede_stale_effect: nil,
      clear_stale_observer: true,
      run: run,
      commit_reconciliation: false,
      finish_reconciliation: false
    )
    allow(ct).to receive_messages(
      lifecycle:,
      state: :running
    )
    allow(ct).to receive(:state=)
    allow(OsCtld::ContainerControl::Commands::State).to receive(:run!)
      .with(ct)
      .and_raise(OsCtld::ContainerControl::Error, 'state query failed')

    expect do
      recovery.recover_state(run_id: run_id)
    end.to raise_error(
      OsCtld::ContainerControl::Error,
      'state query failed'
    )

    expect(ct).not_to have_received(:state=)
    expect(lifecycle).to have_received(:commit_reconciliation).with(
      run_id,
      'reconciliation-1'
    )
    expect(lifecycle).to have_received(:finish_reconciliation).with(
      run_id,
      'reconciliation-1'
    )
  end

  describe '#cleanup' do
    let(:run_id) do
      OsCtld::Container::RunId.new(
        pool_name: 'tank',
        container_id: 'ct1',
        key: 'a' * 32
      )
    end
    let(:run) do
      {
        'id' => run_id.dump,
        'role' => 'active',
        'resources' => { 'cgroup_root' => '/osctl/ct.ct1/runs/aaaaaaaa' },
        'effect' => nil
      }
    end
    let(:lifecycle) do
      double(
        runs: { run_id.to_s => run },
        active_run: run,
        residuals: [],
        revision: 10,
        begin_recovery: OsCtld::Container::Lifecycle::RecoveryLease.new(
          id: 'recovery-1',
          superseded_effect: nil,
          blocking_workers: [],
          busy: false
        ),
        end_recovery: true,
        park_recovery: true,
        record_partial_recovery: true,
        other_runtime_generation?: false,
        policy_tainted?: false,
        clear_policy_taint_after_recovery: false
      )
    end
    let(:ct) do
      double(
        pool: pool,
        id: 'ct1',
        ident: 'tank:ct1',
        netifs: [netif],
        lifecycle:,
        incarnation_id: 'incarnation-1',
        base_cgroup_path: '/osctl/ct.ct1',
        legacy_cgroup_path: '/osctl/ct.ct1/user-owned',
        legacy_wrapper_cgroup_path: '/osctl/ct.ct1/wrapper',
        state: :stopped
      )
    end

    before do
      state_command = stub_const(
        'OsCtld::ContainerControl::Commands::State',
        Class.new do
          def self.run!(_ct); end
        end
      )
      allow(state_command).to receive(:run!).and_return(double(state: :stopped))
      allow(recovery).to receive(:freeze_generation)
      allow(recovery).to receive(:thaw_generation)
      allow(OsCtld::CGroup).to receive(:prevent_forks)
      allow(recovery).to receive(:generation_process_evidence)
        .with(anything, kills: [])
        .and_return([])
      allow(recovery).to receive(:cleanup_generation)
      allow(recovery).to receive_messages(kill_generation: [], manager_process_evidence: [], cleanup_generation_artifacts: [])
      allow(recovery).to receive(:finish_clean_recovery)
      allow(OsCtld::CpuScheduler).to receive(:unschedule_ct)
    end

    it 'returns exact cleaned evidence after all generation resources are gone' do
      result = recovery.cleanup(run_id: run_id.to_s, cleanup: ['cgroups'])

      expect(result).to include(
        outcome: :cleaned,
        run_id: run_id.to_s,
        requested_cleanup: ['cgroups'],
        completed_cleanup: ['cgroups'],
        active_slot_released: false,
        hazards: []
      )
      expect(recovery).to have_received(:finish_clean_recovery).with(
        run_id,
        'recovery-1',
        hash_including('survivors' => []),
        policy_root_removed: false
      )
    end

    it 'rechecks legacy network cleanup when no lifecycle run remains' do
      allow(lifecycle).to receive_messages(
        runs: {},
        active_run: nil,
        residuals: [],
        snapshot: {
          'runs' => {},
          'active_run_id' => nil
        }
      )
      allow(recovery).to receive(:cleanup_netifs).and_return(
        'complete' => true,
        'hazards' => ['network cleanup used legacy route discovery']
      )

      result = recovery.cleanup(cleanup: ['netifs'])

      expect(result).to include(
        outcome: :partial,
        run_id: nil,
        requested_cleanup: ['netifs'],
        completed_cleanup: ['netifs'],
        active_slot_released: false,
        hazards: ['network cleanup used legacy route discovery']
      )
      expect(result[:evidence]).to include('lifecycle_target' => 'none')
      expect(lifecycle).not_to have_received(:begin_recovery)
    end

    it 'clears taint only after explicit recovery verifies the stable root gone' do
      allow(lifecycle).to receive_messages(
        runs: {},
        active_run: nil,
        residuals: [],
        policy_tainted?: true,
        snapshot: {
          'runs' => {},
          'active_run_id' => nil
        }
      )
      allow(OsCtld::CGroup).to receive(:rmpath)
      allow(OsCtld::CGroup).to receive_messages(subsystems: ['cpuset'], abs_cgroup_path: '/definitely-absent/osctl/ct.ct1')

      result = recovery.cleanup(cleanup: ['cgroups'])

      expect(result).to include(
        outcome: :cleaned,
        completed_cleanup: ['cgroups'],
        hazards: []
      )
      expect(OsCtld::CGroup).to have_received(:rmpath).with(
        'cpuset',
        '/osctl/ct.ct1'
      )
      expect(lifecycle).to have_received(
        :clear_policy_taint_after_recovery
      ).with(policy_root_removed: true)
    end

    it 'retains taint when explicit recovery cannot remove the stable root' do
      with_tmpdir do |root|
        allow(lifecycle).to receive_messages(
          runs: {},
          active_run: nil,
          residuals: [],
          policy_tainted?: true,
          snapshot: {
            'runs' => {},
            'active_run_id' => nil
          }
        )
        allow(OsCtld::CGroup).to receive(:rmpath).and_raise(Errno::EBUSY)
        allow(OsCtld::CGroup).to receive_messages(subsystems: ['cpuset'], abs_cgroup_path: root)

        result = recovery.cleanup(cleanup: ['cgroups'])

        expect(result).to include(
          outcome: :blocked,
          completed_cleanup: [],
          hazards: ['stable policy cgroup root could not be removed']
        )
        expect(result[:evidence].fetch('policy_root')).to include(
          'complete' => false,
          'remaining_subsystems' => ['cpuset']
        )
        expect(lifecycle).not_to have_received(
          :clear_policy_taint_after_recovery
        )
      end
    end

    it 'idempotently removes legacy cgroup paths without a lifecycle run' do
      allow(lifecycle).to receive_messages(
        runs: {},
        active_run: nil,
        residuals: [],
        snapshot: {
          'runs' => {},
          'active_run_id' => nil
        }
      )
      allow(OsCtld::CGroup).to receive(:rmpath_all)

      result = recovery.cleanup(cleanup: ['cgroups'])

      expect(result).to include(
        outcome: :cleaned,
        run_id: nil,
        completed_cleanup: ['cgroups'],
        hazards: []
      )
      expect(OsCtld::CGroup).to have_received(:rmpath_all).with(
        '/osctl/ct.ct1/user-owned/lxc.payload.ct1'
      )
      expect(lifecycle).not_to have_received(:begin_recovery)
    end

    it 'atomically selects a launch that became failed historical work' do
      allow(lifecycle).to receive_messages(
        active_run: nil,
        residuals: []
      )
      allow(lifecycle).to receive(:snapshot) do
        run['role'] = 'history'
        run['phase'] = 'failed'
        {
          'runs' => { run_id.to_s => run },
          'active_run_id' => nil
        }
      end

      result = recovery.cleanup(cleanup: ['cgroups'])

      expect(result).to include(
        outcome: :cleaned,
        run_id: run_id.to_s,
        completed_cleanup: ['cgroups']
      )
      expect(recovery).to have_received(:cleanup_generation).with(run_id)
      expect(recovery).to have_received(:finish_clean_recovery).with(
        run_id,
        'recovery-1',
        hash_including('survivors' => []),
        policy_root_removed: false
      )
    end

    it 'quarantines failed historical work when cgroups remain busy' do
      allow(lifecycle).to receive_messages(
        active_run: nil,
        residuals: []
      )
      allow(lifecycle).to receive(:snapshot) do
        run['role'] = 'history'
        run['phase'] = 'failed'
        {
          'runs' => { run_id.to_s => run },
          'active_run_id' => nil
        }
      end
      allow(recovery).to receive(:cleanup_generation).and_raise(Errno::EBUSY)
      allow(lifecycle).to receive(:quarantine).and_return([nil, nil])
      allow(recovery).to receive(:detach_run_configuration)

      result = recovery.cleanup(cleanup: ['cgroups'])

      expect(result).to include(
        outcome: :quarantined,
        run_id: run_id.to_s,
        active_slot_released: false
      )
      expect(lifecycle).to have_received(:quarantine).with(
        run_id,
        recovery_id: 'recovery-1',
        evidence: hash_including('cgroup_error' => include('Errno::EBUSY')),
        hazards: include('generation resources could not be removed')
      )
      expect(recovery).to have_received(:detach_run_configuration).with(
        run_id,
        preserve: true
      )
    end

    it 'blocks when untracked legacy cgroups remain busy' do
      allow(lifecycle).to receive_messages(
        runs: {},
        active_run: nil,
        residuals: [],
        snapshot: {
          'runs' => {},
          'active_run_id' => nil
        }
      )
      allow(OsCtld::CGroup).to receive(:rmpath_all).and_raise(Errno::EBUSY)

      result = recovery.cleanup(cleanup: ['cgroups'])

      expect(result).to include(
        outcome: :blocked,
        run_id: nil,
        completed_cleanup: [],
        active_slot_released: false,
        hazards: ['legacy cgroup resources could not be removed']
      )
      expect(result[:evidence]).to include(
        'cgroup_error' => include('Errno::EBUSY')
      )
      expect(lifecycle).not_to have_received(:begin_recovery)
    end

    it 'blocks an active generation whose recovered state is not stopped' do
      allow(ct).to receive(:state).and_return(:running)
      state_command = OsCtld::ContainerControl::Commands::State

      result = recovery.cleanup(run_id: run_id, cleanup: ['cgroups'])

      expect(result).to include(outcome: :blocked)
      expect(result[:hazards]).to include('LXC is not stopped')
      expect(state_command).not_to have_received(:run!)
      expect(recovery).not_to have_received(:freeze_generation)
    end

    it 'retains a partial generation when exact artifact cleanup fails' do
      allow(recovery).to receive(:cleanup_generation_artifacts).and_return(
        ['unable to remove generation AppArmor resources']
      )
      allow(lifecycle).to receive(:quarantine).and_return([nil, nil])
      allow(recovery).to receive(:detach_run_configuration)

      result = recovery.cleanup(run_id: run_id, cleanup: ['cgroups'])

      expect(result).to include(
        outcome: :partial,
        active_slot_released: true
      )
      expect(lifecycle).to have_received(:quarantine).with(
        run_id,
        recovery_id: 'recovery-1',
        evidence: hash_including('artifact_errors' => include(/AppArmor/)),
        hazards: include(/AppArmor/)
      )
      expect(recovery).not_to have_received(:finish_clean_recovery)
    end

    it 'reports no active slot release for residual artifact failures' do
      run['role'] = 'residual'
      allow(lifecycle).to receive_messages(
        active_run: nil,
        residuals: [run],
        record_partial_recovery: true
      )
      allow(recovery).to receive(:cleanup_generation_artifacts).and_return(
        ['unable to remove generation AppArmor resources']
      )
      allow(lifecycle).to receive(:quarantine)

      result = recovery.cleanup(run_id: run_id, cleanup: ['cgroups'])

      expect(result).to include(
        outcome: :partial,
        active_slot_released: false
      )
      expect(lifecycle).to have_received(:record_partial_recovery).with(
        run_id,
        recovery_id: 'recovery-1',
        evidence: hash_including('artifact_errors' => include(/AppArmor/)),
        hazards: include(/AppArmor/)
      )
      expect(lifecycle).not_to have_received(:quarantine)
    end

    it 'quarantines exact unkillable survivors when managers are gone' do
      survivors = [{ 'pid' => 123, 'state' => 'D', 'kill_delivered' => true }]
      allow(recovery).to receive(:generation_process_evidence)
        .with(anything, kills: [])
        .and_return(survivors)
      allow(recovery).to receive(:cleanup_generation).and_raise(Errno::EBUSY)
      allow(lifecycle).to receive(:quarantine).and_return([nil, nil])
      allow(recovery).to receive(:detach_run_configuration)

      result = recovery.cleanup(run_id: run_id.key, cleanup: ['cgroups'])

      expect(result).to include(
        outcome: :quarantined,
        active_slot_released: true
      )
      expect(result[:evidence]['survivors']).to eq(survivors)
      expect(result[:hazards]).to include(
        'already-entered kernel or ZFS operations may complete later'
      )
      expect(recovery).to have_received(:thaw_generation).with(run_id)
      expect(lifecycle).to have_received(:quarantine).with(
        run_id,
        recovery_id: 'recovery-1',
        evidence: hash_including('survivors' => survivors),
        hazards: include(/already-entered kernel/)
      )
    end

    it 'blocks when an exact quarantine commit is superseded' do
      allow(recovery).to receive(:cleanup_generation).and_raise(Errno::EBUSY)
      allow(lifecycle).to receive(:quarantine).and_return(false)
      allow(recovery).to receive(:detach_run_configuration)

      result = recovery.cleanup(run_id: run_id, cleanup: ['cgroups'])

      expect(result).to include(
        outcome: :blocked,
        active_slot_released: false,
        hazards: ['lifecycle generation quarantine was superseded']
      )
      expect(recovery).not_to have_received(:detach_run_configuration)
      expect(lifecycle).to have_received(:end_recovery).with(
        run_id,
        'recovery-1'
      )
    end

    it 'blocks quarantine while a generation manager can still act' do
      manager = { 'pid' => 456, 'kind' => 'lxc_start', 'alive' => true }
      allow(recovery).to receive(:manager_process_evidence).and_return([manager])
      allow(lifecycle).to receive(:record_partial_recovery)

      result = recovery.cleanup(run_id: run_id, cleanup: ['cgroups'])

      expect(result).to include(outcome: :blocked, active_slot_released: false)
      expect(result[:hazards]).to include(/management process is still alive/)
      expect(recovery).not_to have_received(:cleanup_generation)
    end

    it 'blocks quarantine when a survivor was not identity-qualified for SIGKILL' do
      survivors = [{ 'pid' => 123, 'state' => 'D', 'kill_delivered' => false }]
      allow(recovery).to receive(:generation_process_evidence)
        .with(anything, kills: [])
        .and_return(survivors)
      allow(lifecycle).to receive(:record_partial_recovery)

      result = recovery.cleanup(run_id: run_id, cleanup: ['cgroups'])

      expect(result).to include(outcome: :blocked, active_slot_released: false)
      expect(result[:hazards]).to include(/SIGKILL pending/)
      expect(recovery).not_to have_received(:cleanup_generation)
    end

    it 'accepts SIGKILL pending from an earlier recovery invocation' do
      survivors = [
        {
          'pid' => 123,
          'state' => 'D',
          'kill_delivered' => false,
          'fatal_signal_pending' => true
        }
      ]
      allow(recovery).to receive(:generation_process_evidence)
        .with(anything, kills: [])
        .and_return(survivors)
      allow(recovery).to receive(:cleanup_netifs).and_return(
        'complete' => true,
        'hazards' => []
      )

      result = recovery.cleanup(
        run_id: run_id,
        cleanup: ['netifs']
      )

      expect(result).to include(
        outcome: :partial,
        completed_cleanup: ['netifs']
      )
      expect(lifecycle).to have_received(:end_recovery).with(
        run_id,
        'recovery-1'
      )
    end

    it 'cleans a residual while a replacement generation is running' do
      run['role'] = 'residual'
      allow(lifecycle).to receive_messages(
        active_run: run.merge('id' => run_id.dump.merge('key' => 'b' * 32)),
        residuals: [run],
        other_runtime_generation?: true
      )
      allow(lifecycle).to receive(:remove_residual)
      state_command = OsCtld::ContainerControl::Commands::State

      result = recovery.cleanup(run_id: run_id.key, cleanup: ['cgroups'])

      expect(result).to include(outcome: :cleaned)
      expect(recovery).to have_received(:cleanup_generation).with(run_id)
      expect(state_command).not_to have_received(:run!)
      expect(OsCtld::CpuScheduler).not_to have_received(:unschedule_ct)
    end
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles
