# frozen_string_literal: true

require 'osctld/command'
require 'osctld/container/lifecycle'
require 'osctld/container/lifecycle_executor'
require 'osctld/container/run_configuration'
require 'osctld/container_control/command'
require 'osctld/console'
require 'osctld/switch_user'
require 'osctld/thread_reaper'
require 'osctld/utils/container'
require 'osctld/utils/switch_user'
require 'osctld/commands/container/start'
require 'osctld/group'

RSpec.describe OsCtld::Container::Lifecycle do
  before { stub_daemon }

  let(:pool_class) { Struct.new(:name, :ct_dir) }
  let(:group_class) { Struct.new(:inherited_cgroup_policy_state) }
  let(:container_class) do
    Struct.new(
      :id,
      :pool,
      :incarnation_id,
      :base_cgroup_path,
      :legacy_cgroup_path,
      :legacy_wrapper_cgroup_path,
      :lxc_dir,
      :next_run_conf,
      :run_conf,
      :group,
      keyword_init: true
    )
  end

  def build_container(root, incarnation_id: 'incarnation-1')
    pool = pool_class.new('tank', File.join(root, 'run'))

    container_class.new(
      id: 'ct1',
      pool:,
      incarnation_id:,
      base_cgroup_path: '/osctl/pool.tank/group.default/user.root/ct.ct1',
      legacy_cgroup_path: '/osctl/pool.tank/group.default/user.root/ct.ct1/user-owned',
      legacy_wrapper_cgroup_path: '/osctl/pool.tank/group.default/user.root/ct.ct1/wrapper',
      lxc_dir: '/var/lib/lxc/ct1',
      next_run_conf: nil,
      run_conf: nil,
      group: group_class.new(nil)
    )
  end

  def prepare_restart_interruption(lifecycle, run_id, effect_id)
    pid = Process.spawn('sleep', '30')
    allow(lifecycle).to receive(:watch_process)
    process_id = lifecycle.register_process(
      run_id,
      kind: 'hook:test',
      pid:
    )
    processes = lifecycle.interrupt_daemon_restart_effect(
      run_id,
      expected_effect_id: effect_id,
      expected_phase: lifecycle.run(run_id).fetch('phase'),
      signal: 'TERM'
    )
    expect(processes.map { |v| v.fetch('pid') }).to include(pid)

    Process.wait(pid)
    pid = nil
    lifecycle.finish_process(run_id, process_id)
  ensure
    if pid
      Process.kill('KILL', pid)
      Process.wait(pid)
    end
  end

  def leave_completed_cleanup_worker(lifecycle)
    start = lifecycle.request_start
    start_effect = lifecycle.claim_effect(start.run_id, :start)
    lifecycle.finish_effect(start.run_id, start_effect)
    lifecycle.observe_wrapper_gone(start.run_id)
    cleanup_effect = lifecycle.observe_post_stop(start.run_id)
    Thread.new do
      lifecycle.set_effect_worker(start.run_id, cleanup_effect, Process.pid)
      lifecycle.complete_run(start.run_id, cleanup_effect)
    end.join
    start.run_id
  end

  it 'persists intents and exact generation resources across daemon instances' do
    with_tmpdir do |root|
      ct = build_container(root)
      lifecycle = described_class.new(ct)
      request = lifecycle.request_start(source: 'autostart')

      expect(request.action).to eq(:launch)
      expect(request.run_id.key).to match(/\A[0-9a-f]{32}\z/)
      expect(lifecycle.active_run.dig('resources', 'cgroup_root'))
        .to end_with("/runs/#{request.run_id.key}")

      restored = described_class.new(ct)

      expect(restored.desired_state).to eq(:running)
      expect(restored.current_intent_source).to eq('autostart')
      expect(restored.autostart_intent?).to be(true)
      expect(restored.active_run_id).to eq(request.run_id)
      expect(restored.revision).to be > 0
    end
  end

  it 'persists a handoff intent without allocating a launch generation' do
    with_tmpdir do |root|
      ct = build_container(root)
      lifecycle = described_class.new(ct)

      intent_id = lifecycle.persist_running_intent(
        source: 'legacy-runtime-upgrade'
      )

      expect(intent_id).to eq(lifecycle.current_intent_id)
      expect(lifecycle.desired_state).to eq(:running)
      expect(lifecycle.current_intent_source).to eq(
        'legacy-runtime-upgrade'
      )
      expect(lifecycle.active_run).to be_nil
      expect(lifecycle.daemon_restart_blockers).to be_empty
    end
  end

  it 'reports every active and residual runtime generation' do
    with_tmpdir do |root|
      ct = build_container(root)
      lifecycle = described_class.new(ct)
      active = lifecycle.request_start.run_id
      effect_id = lifecycle.claim_effect(active, :start)
      recovery = lifecycle.begin_recovery(active)
      lifecycle.quarantine(
        active,
        recovery_id: recovery.id,
        evidence: { 'survivors' => [{ 'pid' => 123 }] },
        hazards: ['unkillable process']
      )
      replacement = lifecycle.request_start.run_id

      expect(
        lifecycle.runtime_generations.map do |run|
          [run.fetch('role'), OsCtld::Container::RunId.load(run.fetch('id'))]
        end
      ).to contain_exactly(
        ['residual', active],
        ['active', replacement]
      )
      expect(effect_id).not_to be_nil
    end
  end

  it 'refuses to archive an active record for a different incarnation' do
    with_tmpdir do |root|
      old_ct = build_container(root, incarnation_id: 'incarnation-old')
      lifecycle = described_class.new(old_ct)
      lifecycle.request_start

      expect do
        described_class.new(
          build_container(root, incarnation_id: 'incarnation-new')
        )
      end.to raise_error(
        OsCtld::ConfigError,
        /has runtime or quarantined policy evidence/
      )
      expect(
        Dir.glob(
          File.join(root, 'run', 'ct1', 'lifecycle.yml.incarnation-*')
        )
      ).to be_empty
    end
  end

  it 'refuses to archive residual evidence for a different incarnation' do
    with_tmpdir do |root|
      old_ct = build_container(root, incarnation_id: 'incarnation-old')
      lifecycle = described_class.new(old_ct)
      run_id = lifecycle.request_start.run_id
      lifecycle.claim_effect(run_id, :start)
      recovery = lifecycle.begin_recovery(run_id)
      lifecycle.quarantine(
        run_id,
        recovery_id: recovery.id,
        evidence: { 'survivors' => [{ 'pid' => 123 }] },
        hazards: ['unkillable process']
      )

      expect do
        described_class.new(
          build_container(root, incarnation_id: 'incarnation-new')
        )
      end.to raise_error(
        OsCtld::ConfigError,
        /has runtime or quarantined policy evidence/
      )
    end
  end

  it 'refuses to archive policy taint for a different incarnation' do
    with_tmpdir do |root|
      old_ct = build_container(root, incarnation_id: 'incarnation-old')
      lifecycle = described_class.new(old_ct)
      lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)
      lifecycle.finish_policy_update(
        lease.id,
        rollback_error: 'cgroup rollback failed'
      )

      expect do
        described_class.new(
          build_container(root, incarnation_id: 'incarnation-new')
        )
      end.to raise_error(
        OsCtld::ConfigError,
        /has runtime or quarantined policy evidence/
      )
    end
  end

  it 'archives a drained record for a different incarnation' do
    with_tmpdir do |root|
      old_ct = build_container(root, incarnation_id: 'incarnation-old')
      lifecycle = described_class.new(old_ct)
      lifecycle.request_stop

      replacement = described_class.new(
        build_container(root, incarnation_id: 'incarnation-new')
      )

      expect(replacement.snapshot.fetch('incarnation_id'))
        .to eq('incarnation-new')
      expect(
        Dir.glob(
          File.join(root, 'run', 'ct1', 'lifecycle.yml.incarnation-*')
        ).length
      ).to eq(1)
    end
  end

  it 'normalizes a dead completed cleanup worker on reload' do
    with_tmpdir do |root|
      ct = build_container(root)
      lifecycle = described_class.new(ct)
      run_id = leave_completed_cleanup_worker(lifecycle)

      expect(lifecycle.run(run_id).fetch('effect')).to include(
        'status' => 'completed'
      )
      restored = described_class.new(ct)

      expect(restored.run(run_id).fetch('effect')).to be_nil
      expect(restored.run(run_id)).to include(
        'role' => 'history',
        'phase' => 'clean'
      )
    end
  end

  it 'archives a drained completed worker for a different incarnation' do
    with_tmpdir do |root|
      old_ct = build_container(root, incarnation_id: 'incarnation-old')
      lifecycle = described_class.new(old_ct)
      leave_completed_cleanup_worker(lifecycle)

      replacement = described_class.new(
        build_container(root, incarnation_id: 'incarnation-new')
      )

      expect(replacement.snapshot.fetch('incarnation_id'))
        .to eq('incarnation-new')
      expect(
        Dir.glob(
          File.join(root, 'run', 'ct1', 'lifecycle.yml.incarnation-*')
        ).length
      ).to eq(1)
    end
  end

  it 'prunes clean history after a completed worker is dead' do
    with_tmpdir do |root|
      ct = build_container(root)
      lifecycle = described_class.new(ct)
      run_id = leave_completed_cleanup_worker(lifecycle)
      restored = described_class.new(ct)

      replacement = restored.request_start

      expect(replacement.action).to eq(:launch)
      expect(restored.run(run_id)).to be_nil
    end
  end

  it 'uses a run configuration prepared while creating a new container' do
    with_tmpdir do |root|
      ct = build_container(root)
      planned_id = OsCtld::Container::RunId.new(
        pool_name: 'tank',
        container_id: 'ct1'
      )
      ct.run_conf = Struct.new(:run_id).new(planned_id)

      request = described_class.new(ct).request_start

      expect(request.run_id).to eq(planned_id)
    end
  end

  it 'leases id-less callbacks only to an explicitly adopted legacy run' do
    with_tmpdir do |root|
      ct = build_container(root)
      lifecycle = described_class.new(ct)
      run_id = OsCtld::Container::RunId.new(
        pool_name: 'tank',
        container_id: 'ct1'
      )
      run_conf = Struct.new(:run_id, :reboot?).new(run_id, false)
      identity = OsCtld::ProcessIdentity.capture(Process.pid)
      manager = identity.dump.merge('kind' => 'legacy_wrapper')

      expect(lifecycle.adopted_legacy_callback_run_id).to be_nil

      lifecycle.adopt_legacy(run_conf, :running, managers: [manager])

      expect(lifecycle.adopted_legacy_callback_run_id).to eq(run_id)
      expect(lifecycle.active_run.fetch('legacy_callbacks')).to be(true)
      expect(lifecycle.active_run.fetch('legacy_managers')).to eq([manager])
      expect(lifecycle.running_intent_id).not_to be_nil
      expect(lifecycle.active_run.fetch('launch_intent_id'))
        .to eq(lifecycle.running_intent_id)
    end
  end

  it 'adopts a frozen legacy runtime as the same desired-running generation' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      run_id = OsCtld::Container::RunId.new(
        pool_name: 'tank',
        container_id: 'ct1'
      )
      run_conf = Struct.new(:run_id, :reboot?).new(run_id, false)
      manager = OsCtld::ProcessIdentity.capture(Process.pid).dump.merge(
        'kind' => 'legacy_wrapper'
      )

      lifecycle.adopt_legacy(run_conf, :frozen, managers: [manager])

      expect(lifecycle.desired_state).to eq(:running)
      expect(lifecycle.running_intent_id).not_to be_nil
      expect(lifecycle.active_run).to include(
        'phase' => 'running',
        'reported_state' => 'frozen',
        'launch_intent_id' => lifecycle.running_intent_id
      )
      expect(lifecycle.daemon_restart_blockers).to be_empty
    end
  end

  it 'does not consider a stale adopted manager identity stable' do
    %i[running frozen].each do |state|
      with_tmpdir do |root|
        lifecycle = described_class.new(build_container(root))
        run_id = OsCtld::Container::RunId.new(
          pool_name: 'tank',
          container_id: 'ct1'
        )
        run_conf = Struct.new(:run_id, :reboot?).new(run_id, false)
        stale_manager = {
          'pid' => 999_999_999,
          'start_time_ticks' => 1,
          'kind' => 'legacy_wrapper'
        }

        lifecycle.adopt_legacy(
          run_conf,
          state,
          managers: [stale_manager]
        )

        expect(lifecycle.daemon_restart_blockers).to contain_exactly(
          include(
            type: 'container_generation',
            run_id: run_id.to_s,
            phase: 'running'
          )
        )
      end
    end
  end

  it 'blocks restart readiness for a legacy runtime without a manager identity' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      run_id = OsCtld::Container::RunId.new(
        pool_name: 'tank',
        container_id: 'ct1'
      )
      run_conf = Struct.new(:run_id, :reboot?).new(run_id, false)

      lifecycle.adopt_legacy(run_conf, :running, managers: [])

      expect(lifecycle.daemon_restart_blockers).to contain_exactly(
        include(
          type: 'container_generation',
          run_id: run_id.to_s,
          phase: 'running'
        )
      )
    end
  end

  it 'blocks unrelated manipulation until a run is stably running' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start

      expect(lifecycle.manipulation_blocker).to include(phase: 'preparing')

      effect_id = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      expect(lifecycle.manipulation_blocker).to include(
        phase: 'running',
        effect: 'start'
      )

      lifecycle.finish_effect(start.run_id, effect_id)
      expect(lifecycle.manipulation_blocker).to be_nil

      lifecycle.request_stop
      expect(lifecycle.manipulation_blocker).to include(phase: 'running')
    end
  end

  it 'fences finalization while a runtime policy transaction is active' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, start_effect)
      lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)

      expect(lease).not_to be_nil
      expect(lifecycle.manipulation_blocker).to include(
        phase: 'policy_update',
        effect: 'cpuset_cpus'
      )
      expect(
        lifecycle.register_attachment(start.run_id, pid: Process.pid)
      ).to be_nil
      callback_ready = Queue.new
      callback_result = Queue.new
      callback_thread = Thread.new do
        callback_ready << true
        callback_result << lifecycle.begin_callback(
          start.run_id,
          name: :policy_race
        )
      end
      callback_ready.pop
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        callbacks = lifecycle.active_run.fetch('callbacks')
        break unless callbacks.empty?

        raise 'callback was not persisted' if Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        ) >= deadline

        Thread.pass
      end
      expect(callback_thread).to be_alive
      expect(callback_result).to be_empty

      stop = lifecycle.request_stop
      expect(lifecycle.claim_effect(stop.run_id, :stop)).to be_nil
      expect(lifecycle.observe_wrapper_gone(start.run_id)).to be(false)
      expect(lifecycle.observe_post_stop(start.run_id)).to be(false)

      completion = lifecycle.finish_policy_update(
        lease.id,
        target: '2-4',
        run_masks: { start.run_id.to_s => '2-4' }
      )

      expect(completion.run_id).to eq(start.run_id)
      expect(completion.effect_id).to be_nil
      callback_id = callback_result.pop
      callback_thread.join
      expect(callback_id).to be_a(String)
      cleanup_effect = lifecycle.finish_callback(start.run_id, callback_id)
      expect(cleanup_effect).to be_a(String)
      expect(lifecycle.active_phase).to eq(:cleaning)
      expect(
        lifecycle.run(start.run_id).dig('policy', 'cpuset_cpus')
      ).to eq('2-4')
    end
  end

  it 'rejects a launch callback woken by local policy quarantine' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, effect_id)
      lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)
      callback = Thread.new do
        lifecycle.begin_callback(start.run_id, name: 'CtPreStart')
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        break unless lifecycle.active_run.fetch('callbacks').empty?

        raise 'callback was not persisted' if Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        ) >= deadline

        Thread.pass
      end

      lifecycle.finish_policy_update(
        lease.id,
        error: 'write failed',
        rollback_error: 'rollback failed'
      )

      expect(callback.join(3)).to equal(callback)
      expect(callback.value).to be_nil
      expect(lifecycle.active_run.fetch('callbacks')).to be_empty
      teardown_id = lifecycle.begin_callback(
        start.run_id,
        name: 'CtPostStop'
      )
      expect(teardown_id).to be_a(String)
      lifecycle.finish_callback(start.run_id, teardown_id)
    end
  end

  it 'rejects a launch callback woken by ancestor group quarantine' do
    with_tmpdir do |root|
      state = nil
      group = instance_double(
        OsCtld::Group,
        pool: Struct.new(:name).new('tank'),
        name: '/limited'
      )
      allow(group).to receive(:inherited_cgroup_policy_state) do
        state && [group, state]
      end
      ct = build_container(root)
      ct.group = group
      lifecycle = described_class.new(ct)
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, effect_id)
      lease = lifecycle.begin_parent_policy_update(kind: :group_cpuset)
      callback = Thread.new do
        lifecycle.begin_callback(start.run_id, name: 'VethUp')
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        break unless lifecycle.active_run.fetch('callbacks').empty?

        raise 'callback was not persisted' if Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        ) >= deadline

        Thread.pass
      end
      state = {
        'status' => 'tainted',
        'rollback_error' => 'parent rollback failed'
      }

      lifecycle.finish_parent_policy_update(
        lease.id,
        error: 'group write failed'
      )

      expect(callback.join(3)).to equal(callback)
      expect(callback.value).to be_nil
      expect(lifecycle.active_run.fetch('callbacks')).to be_empty
    end
  end

  it 'reports a live runtime policy worker to exceptional recovery' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, start_effect)
      policy_lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)

      recovery_lease = lifecycle.begin_recovery(start.run_id)

      expect(recovery_lease.busy).to be(true)
      expect(recovery_lease.blocking_workers).to include(
        hash_including(
          'kind' => 'policy_update',
          'id' => policy_lease.id
        )
      )
      expect(lifecycle.run(start.run_id)['recovery']).to be_nil
      lifecycle.finish_policy_update(policy_lease.id)
    end
  end

  it 'taints an orphaned policy lease until explicit cgroup recovery' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)
      worker_cfg = lifecycle.snapshot.fetch('policy_update').fetch('worker')
      dead_worker = instance_double(OsCtld::ProcessIdentity, alive?: false)

      allow(OsCtld::ProcessIdentity).to receive(:load)
        .with(worker_cfg)
        .and_return(dead_worker)

      expect(lifecycle.manipulation_blocker).to include(
        phase: 'policy_tainted',
        effect: 'cpuset_cpus'
      )
      expect(lifecycle.policy_update_current?(lease.id)).to be(false)
      expect(lifecycle.snapshot.fetch('policy')).to include(
        'kind' => 'cpuset_cpus',
        'tainted' => true,
        'rollback_error' => 'runtime cgroup policy may be partially applied'
      )

      allow(OsCtld::ProcessIdentity).to receive(:load).and_call_original
      recovery_lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)
      lifecycle.finish_policy_update(
        recovery_lease.id,
        target: '0-3',
        error: 'reconciliation failed'
      )

      expect(lifecycle.policy_tainted?).to be(true)

      recovery_lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)
      lifecycle.finish_policy_update(recovery_lease.id, target: '0-3')

      expect(lifecycle.policy_tainted?).to be(true)
      expect(lifecycle.request_start.action).to eq(:blocked)
      expect(
        lifecycle.clear_policy_taint_after_recovery(
          policy_root_removed: true
        )
      ).to be(true)
      expect(lifecycle.policy_tainted?).to be(false)
      expect(lifecycle.manipulation_blocker).to be_nil
    end
  end

  it 'turns an orphaned launch-policy marker into an exported taint' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      lifecycle.claim_effect(start.run_id, :start)
      lease = lifecycle.begin_launch_policy(
        start.run_id,
        kind: :cpuset_cpus
      )
      worker_cfg = lifecycle.snapshot.fetch('policy_update').fetch('worker')
      dead_worker = instance_double(OsCtld::ProcessIdentity, alive?: false)

      allow(OsCtld::ProcessIdentity).to receive(:load)
        .with(worker_cfg)
        .and_return(dead_worker)

      exported = lifecycle.snapshot

      expect(exported['policy_update']).to be_nil
      expect(exported.fetch('policy')).to include(
        'kind' => 'cpuset_cpus',
        'tainted' => true,
        'rollback_error' => 'runtime cgroup policy may be partially applied'
      )
      expect(lifecycle.policy_update_current?(lease.id)).to be(false)
      expect(
        lifecycle.begin_launch_policy(
          start.run_id,
          kind: :cpuset_cpus
        )
      ).to be_nil
      expect(
        lifecycle.record_launch_policy(
          start.run_id,
          lease_id: lease.id,
          target: '0-3',
          error: 'second launch reconciliation failed'
        )
      ).to be(false)
      expect(lifecycle.policy_tainted?).to be(true)
    end
  end

  it 'finishes an exact launch-policy marker after LXC reaches running' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      lifecycle.claim_effect(start.run_id, :start)
      lease = lifecycle.begin_launch_policy(
        start.run_id,
        kind: :cpuset_cpus
      )

      lifecycle.observe_state(
        start.run_id,
        :running,
        init_pid: Process.pid
      )

      expect(
        lifecycle.record_launch_policy(
          start.run_id,
          lease_id: lease.id,
          target: '0-3',
          run_masks: { start.run_id.to_s => '0-3' }
        )
      ).to be(true)
      expect(lifecycle.snapshot['policy_update']).to be_nil
      expect(lifecycle.policy_tainted?).to be(false)
    end
  end

  it 'retains the exact launch policy kind when rollback is incomplete' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      lifecycle.claim_effect(start.run_id, :start)
      lease = lifecycle.begin_launch_policy(
        start.run_id,
        kind: :cpu_bandwidth
      )

      expect(
        lifecycle.record_launch_policy(
          start.run_id,
          lease_id: lease.id,
          target: {
            'quota_us' => 50_000,
            'period_us' => 100_000
          },
          error: 'CPU launch apply failed',
          rollback_error: 'CPU launch rollback failed'
        )
      ).to be(true)
      expect(lifecycle.snapshot.fetch('policy')).to include(
        'kind' => 'cpu_bandwidth',
        'tainted' => true,
        'rollback_error' => 'CPU launch rollback failed'
      )
    end
  end

  it 'records a reconciliation hazard when no topology lease was acquired' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))

      expect(
        lifecycle.record_policy_hazard(
          kind: :cpu_bandwidth,
          target: [{ 'name' => 'cpu.max', 'value' => ['250000 100000'] }],
          error: 'adopted payload disappeared',
          rollback_error: 'adopted payload bandwidth is not proven safe'
        )
      ).to be(true)

      expect(lifecycle.snapshot.fetch('policy')).to include(
        'kind' => 'cpu_bandwidth',
        'error' => 'adopted payload disappeared',
        'rollback_error' =>
          'adopted payload bandwidth is not proven safe',
        'tainted' => true
      )
      expect(
        lifecycle.snapshot.dig(
          'policy',
          'pending_hazards',
          0,
          'kind'
        )
      ).to eq('cpu_bandwidth')
      expect(lifecycle.request_start.action).to eq(:blocked)
    end
  end

  it 'carries an adoption hazard through a live container policy lease' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)
      target = [{ 'name' => 'cpu.max', 'value' => ['250000 100000'] }]

      expect(
        lifecycle.record_policy_hazard(
          kind: :cpu_bandwidth,
          target:,
          error: 'adopted CPU reconciliation could not acquire a lease',
          rollback_error: 'adopted payload bandwidth is not proven safe'
        )
      ).to be(true)
      expect(
        lifecycle.snapshot.dig(
          'policy_update',
          'pending_hazards',
          0,
          'kind'
        )
      ).to eq('cpu_bandwidth')

      lifecycle.finish_policy_update(lease.id, target: '0-3')

      policy = lifecycle.snapshot.fetch('policy')
      expect(policy).to include(
        'kind' => 'cpu_bandwidth',
        'target' => target,
        'error' => 'adopted CPU reconciliation could not acquire a lease',
        'rollback_error' =>
          'adopted payload bandwidth is not proven safe',
        'tainted' => true
      )
      expect(policy.fetch('pending_hazards')).to contain_exactly(
        hash_including('kind' => 'cpu_bandwidth', 'target' => target)
      )
      expect(policy.fetch('last_reconciliation')).to include(
        'target' => '0-3',
        'error' => nil,
        'rollback_error' => nil
      )
      expect(lifecycle.request_start.action).to eq(:blocked)
    end
  end

  it 'carries an adoption hazard through a live parent policy lease' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      lease = lifecycle.begin_parent_policy_update(kind: :group_cpuset)
      target = [{ 'name' => 'cpu.max', 'value' => ['250000 100000'] }]

      expect(
        lifecycle.record_policy_hazard(
          kind: :cpu_bandwidth,
          target:,
          error: 'adopted CPU reconciliation could not acquire a lease',
          rollback_error: 'adopted payload bandwidth is not proven safe'
        )
      ).to be(true)

      lifecycle.finish_parent_policy_update(lease.id)

      expect(lifecycle.snapshot.fetch('policy')).to include(
        'kind' => 'cpu_bandwidth',
        'target' => target,
        'error' => 'adopted CPU reconciliation could not acquire a lease',
        'rollback_error' =>
          'adopted payload bandwidth is not proven safe',
        'tainted' => true
      )
      expect(lifecycle.request_start.action).to eq(:blocked)
    end
  end

  it 'carries an adoption hazard through an exact launch policy lease' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      lifecycle.claim_effect(start.run_id, :start)
      lease = lifecycle.begin_launch_policy(
        start.run_id,
        kind: :cpuset_cpus
      )
      target = [{ 'name' => 'cpu.max', 'value' => ['250000 100000'] }]

      expect(
        lifecycle.record_policy_hazard(
          kind: :cpu_bandwidth,
          target:,
          error: 'adopted CPU reconciliation could not acquire a lease',
          rollback_error: 'adopted payload bandwidth is not proven safe'
        )
      ).to be(true)
      expect(
        lifecycle.record_launch_policy(
          start.run_id,
          lease_id: lease.id,
          target: '0-3'
        )
      ).to be(true)

      policy = lifecycle.snapshot.fetch('policy')
      expect(policy).to include(
        'kind' => 'cpu_bandwidth',
        'target' => target,
        'error' => 'adopted CPU reconciliation could not acquire a lease',
        'rollback_error' =>
          'adopted payload bandwidth is not proven safe',
        'tainted' => true
      )
      expect(policy.fetch('last_reconciliation')).to include(
        'target' => '0-3',
        'error' => nil,
        'rollback_error' => nil
      )
      expect(lifecycle.request_start.action).to eq(:blocked)
    end
  end

  it 'retains an adoption hazard when a container policy worker dies' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      lifecycle.begin_policy_update(kind: :cpuset_cpus)
      target = [{ 'name' => 'cpu.max', 'value' => ['250000 100000'] }]
      lifecycle.record_policy_hazard(
        kind: :cpu_bandwidth,
        target:,
        error: 'adopted CPU reconciliation could not acquire a lease',
        rollback_error: 'adopted payload bandwidth is not proven safe'
      )
      worker_cfg = lifecycle.snapshot.fetch('policy_update').fetch('worker')
      dead_worker = instance_double(OsCtld::ProcessIdentity, alive?: false)
      allow(OsCtld::ProcessIdentity).to receive(:load)
        .with(worker_cfg)
        .and_return(dead_worker)

      policy = lifecycle.snapshot.fetch('policy')

      expect(policy).to include(
        'kind' => 'cpuset_cpus',
        'tainted' => true,
        'rollback_error' => 'runtime cgroup policy may be partially applied'
      )
      expect(policy.fetch('pending_hazards')).to contain_exactly(
        hash_including('kind' => 'cpu_bandwidth', 'target' => target)
      )
      expect(lifecycle.request_start.action).to eq(:blocked)
    end
  end

  it 'retains a promoted adoption hazard when reconciliation dies' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      target = [{ 'name' => 'cpu.max', 'value' => ['250000 100000'] }]
      lifecycle.record_policy_hazard(
        kind: :cpu_bandwidth,
        target:,
        error: 'adopted CPU reconciliation could not acquire a lease',
        rollback_error: 'adopted payload bandwidth is not proven safe'
      )
      lifecycle.begin_policy_update(kind: :cpuset_cpus)
      worker_cfg = lifecycle.snapshot.fetch('policy_update').fetch('worker')
      dead_worker = instance_double(OsCtld::ProcessIdentity, alive?: false)
      allow(OsCtld::ProcessIdentity).to receive(:load)
        .with(worker_cfg)
        .and_return(dead_worker)

      policy = lifecycle.snapshot.fetch('policy')

      expect(policy).to include(
        'kind' => 'cpuset_cpus',
        'tainted' => true,
        'error' => 'adopted CPU reconciliation could not acquire a lease',
        'rollback_error' =>
          'adopted payload bandwidth is not proven safe'
      )
      expect(policy.fetch('pending_hazards')).to contain_exactly(
        hash_including('kind' => 'cpu_bandwidth', 'target' => target)
      )
      expect(policy.fetch('last_reconciliation')).to include(
        'target' => nil,
        'error' =>
          'policy worker disappeared before completing the transaction',
        'rollback_error' => 'runtime cgroup policy may be partially applied'
      )
      expect(lifecycle.request_start.action).to eq(:blocked)
    end
  end

  it 'retains an adoption hazard when a parent policy worker dies' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      lifecycle.begin_parent_policy_update(kind: :group_cpuset)
      target = [{ 'name' => 'cpu.max', 'value' => ['250000 100000'] }]
      lifecycle.record_policy_hazard(
        kind: :cpu_bandwidth,
        target:,
        error: 'adopted CPU reconciliation could not acquire a lease',
        rollback_error: 'adopted payload bandwidth is not proven safe'
      )
      worker_cfg = lifecycle.snapshot.fetch('policy_update').fetch('worker')
      dead_worker = instance_double(OsCtld::ProcessIdentity, alive?: false)
      allow(OsCtld::ProcessIdentity).to receive(:load)
        .with(worker_cfg)
        .and_return(dead_worker)

      policy = lifecycle.snapshot.fetch('policy')

      expect(policy).to include(
        'kind' => 'cpu_bandwidth',
        'target' => target,
        'tainted' => true,
        'rollback_error' => 'adopted payload bandwidth is not proven safe'
      )
      expect(policy.fetch('last_reconciliation').fetch('error')).to match(
        /parent policy worker disappeared/
      )
      expect(lifecycle.request_start.action).to eq(:blocked)
    end
  end

  it 'admits exact child-policy reconciliation after pre-start handoff' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.mark_launching(start.run_id, effect_id, Process.pid)
      lifecycle.authorize_lxc_start(start.run_id, Process.pid)
      lifecycle.activate_lxc_start(start.run_id, Process.pid)
      pre_start_id = lifecycle.begin_callback(
        start.run_id,
        name: 'CtPreStart'
      )
      lifecycle.consume_pre_start(
        start.run_id,
        client_pid: Process.pid,
        callback_id: pre_start_id
      )
      lifecycle.complete_pre_start(
        start.run_id,
        callback_id: pre_start_id
      )
      lifecycle.finish_callback(start.run_id, pre_start_id)
      on_start_id = lifecycle.begin_callback(
        start.run_id,
        name: 'CtOnStart'
      )

      lease = lifecycle.begin_launch_policy(
        start.run_id,
        kind: :cpuset_cpus
      )

      expect(lease).not_to be_nil
      expect(
        lifecycle.record_launch_policy(
          start.run_id,
          lease_id: lease.id,
          target: '0-3',
          run_masks: { start.run_id.to_s => '0-3' }
        )
      ).to be(true)
      expect(lifecycle.finish_callback(start.run_id, on_start_id)).to be(false)
      expect(lifecycle.policy_tainted?).to be(false)
    end
  end

  it 'fences start and stopped execution admission during a policy update' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)

      expect(lifecycle.request_start.action).to eq(:wait)
      expect(lifecycle.request_execution.action).to eq(:wait)
      expect(lifecycle.request_restart.action).to eq(:wait)
      expect(lifecycle.request_control_reboot.action).to eq(:wait)
      expect(lifecycle.active_run_id).to be_nil

      lifecycle.finish_policy_update(lease.id, target: '0-3')

      expect(lifecycle.request_execution.action).to eq(:launch)
    end
  end

  it 'wakes a lifecycle waiter when a policy worker disappears' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      ready = Queue.new
      release = Queue.new
      worker = Thread.new do
        lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)
        ready << lease
        release.pop
      end
      lease = ready.pop
      request = lifecycle.request_start
      result = Queue.new
      waiter = Thread.new do
        result << lifecycle.wait_for_change(request.revision, timeout: 3)
      end

      release << true
      worker.join

      expect(result.pop).to be(true)
      waiter.join
      expect(lifecycle.policy_tainted?).to be(true)
      expect(lifecycle.request_start.action).to eq(:blocked)
      expect(lifecycle.snapshot['policy_update']).to be_nil
      expect(lifecycle.snapshot.dig('policy', 'error'))
        .to match(/policy worker disappeared/)
      expect(lease).not_to be_nil
    end
  end

  it 'blocks new generations below a quarantined empty group' do
    with_tmpdir do |root|
      state = {
        'status' => 'tainted',
        'rollback_error' => 'parent rollback failed'
      }
      group = instance_double(
        OsCtld::Group,
        pool: Struct.new(:name).new('tank'),
        name: '/quarantined',
        inherited_cgroup_policy_state: nil
      )
      allow(group).to receive(:inherited_cgroup_policy_state)
        .and_return([group, state])
      ct = build_container(root)
      ct.group = group
      lifecycle = described_class.new(ct)
      request = lifecycle.request_start

      expect(request.action).to eq(:blocked)
      expect(request.warning).to match(
        %r{
          ancestor\ group\ tank:/quarantined
          .*parent\ rollback\ failed
          .*osctl\ group\ cgparams\ apply\ tank:/quarantined
        }x
      )
      expect(lifecycle.request_execution.action).to eq(:blocked)
      expect(lifecycle.request_restart.action).to eq(:blocked)
      expect(lifecycle.begin_policy_update(kind: :cpuset_cpus)).to be_nil
    end
  end

  it 'atomically fences parent policy writes from policy failure and recovery' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, effect_id)

      child_lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)
      expect(
        lifecycle.begin_parent_policy_update(kind: :group_cpuset)
      ).to be_nil
      lifecycle.finish_policy_update(
        child_lease.id,
        target: '0-3',
        error: 'policy write failed'
      )

      recovery_lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)
      lifecycle.finish_policy_update(recovery_lease.id, target: '0-3')
      parent_lease = lifecycle.begin_parent_policy_update(
        kind: :group_cpuset
      )
      expect(parent_lease).not_to be_nil

      recovery = lifecycle.begin_recovery(start.run_id)
      expect(recovery.busy).to be(true)
      expect(recovery.blocking_workers)
        .to include(a_hash_including('kind' => 'policy_update'))
      expect(lifecycle.run(start.run_id)['recovery']).to be_nil

      completion = lifecycle.finish_parent_policy_update(parent_lease.id)
      expect(completion.run_id).to eq(start.run_id)
      expect(lifecycle.snapshot['policy_update']).to be_nil
    end
  end

  it 'blocks ordinary launch admission while the cgroup policy is tainted' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)
      lifecycle.finish_policy_update(
        lease.id,
        target: '0-3',
        error: 'write failed',
        rollback_error: 'rollback failed'
      )

      start = lifecycle.request_start
      expect(start.action).to eq(:blocked)
      expect(start.warning).to match(/policy is tainted/)
      expect(lifecycle.request_execution.action).to eq(:blocked)
      expect(lifecycle.request_restart.action).to eq(:blocked)
      expect(lifecycle.request_control_reboot.action).to eq(:blocked)
      expect(lifecycle.active_run_id).to be_nil
    end
  end

  it 'admits direct reboot only for a stable running generation' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))

      stopped = lifecycle.request_control_reboot
      expect(stopped.action).to eq(:blocked)
      expect(stopped.warning).to eq('container is not running')

      start = lifecycle.request_start
      expect(lifecycle.request_control_reboot.action).to eq(:wait)
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      expect(lifecycle.request_control_reboot.action).to eq(:wait)
      lifecycle.finish_effect(start.run_id, effect_id)

      ready = lifecycle.request_control_reboot
      expect(ready.action).to eq(:ready)
      expect(ready.run_id).to eq(start.run_id)
      expect(ready.effect_id).not_to be_nil
      expect(
        lifecycle.run(start.run_id).dig('effect', 'type')
      ).to eq('control_reboot')
      expect(lifecycle.request_start.action).to eq(:wait)
      expect(lifecycle.begin_policy_update(kind: :cpuset_cpus)).to be_nil
      expect(lifecycle.supersede_stale_effect(start.run_id)).to be_nil
      expect(
        lifecycle.record_control_reboot_error(
          start.run_id,
          ready.effect_id,
          'runner reply was lost'
        )
      ).to be(true)
      expect(lifecycle.run(start.run_id).fetch('effect')).to include(
        'id' => ready.effect_id,
        'type' => 'control_reboot',
        'status' => 'delivery_unknown',
        'delivery_error' => 'runner reply was lost'
      )
      expect(lifecycle.request_start.action).to eq(:wait)

      expect(lifecycle.observe_wrapper_gone(start.run_id)).to be(false)
      cleanup_effect = lifecycle.observe_post_stop(start.run_id)
      expect(cleanup_effect).not_to be_nil
      expect(lifecycle.run(start.run_id)).to include(
        'reboot' => true,
        'phase' => 'cleaning'
      )
      expect(lifecycle.desired_state).to eq(:running)
    end
  end

  it 'issues stop while a live attachment remains a finalization fence' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(
        start.run_id,
        :running,
        init_pid: Process.pid
      )
      lifecycle.finish_effect(start.run_id, start_effect)
      process_id = lifecycle.register_attachment(
        start.run_id,
        pid: Process.pid
      )

      stop = lifecycle.request_stop
      expect(stop.action).to eq(:stop)
      stop_effect = lifecycle.claim_effect(stop.run_id, :stop)
      expect(stop_effect).not_to be_nil
      expect(lifecycle.finish_process(start.run_id, process_id)).to be(false)
      expect(lifecycle.finish_effect(start.run_id, stop_effect)).to be(true)

      expect(lifecycle.observe_wrapper_gone(start.run_id)).to be(false)
      cleanup_effect = lifecycle.observe_post_stop(start.run_id)
      expect(cleanup_effect).not_to be_nil
    end
  end

  it 'lets explicit stop supersede a reboot reservation after daemon loss' do
    with_tmpdir do |root|
      ct = build_container(root)
      lifecycle = described_class.new(ct)
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(
        start.run_id,
        :running,
        init_pid: Process.pid
      )
      lifecycle.finish_effect(start.run_id, start_effect)
      reboot = lifecycle.request_control_reboot

      reloaded = described_class.new(ct)
      expect(reloaded.request_start.action).to eq(:wait)
      expect(reloaded.supersede_stale_effect(start.run_id)).to be_nil

      stop = reloaded.request_stop
      expect(stop.action).to eq(:stop)
      expect(reloaded.claim_effect(stop.run_id, :stop)).not_to be_nil
      expect(reloaded.run(start.run_id).fetch('hazards')).to include(
        "stop superseded pending control reboot effect #{reboot.effect_id}"
      )
    end
  end

  it 'fences observations and automatic reconciliation during policy updates' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(
        start.run_id,
        :running,
        init_pid: Process.pid
      )
      lifecycle.finish_effect(start.run_id, start_effect)
      lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)

      expect(
        lifecycle.begin_state_observation(
          start.run_id,
          :running,
          source: 'monitor'
        )
      ).to be_nil
      expect(
        lifecycle.begin_reconciliation(
          start.run_id,
          source: 'daemon_restart'
        )
      ).to be_nil

      lifecycle.finish_policy_update(
        lease.id,
        error: 'write failed',
        rollback_error: 'rollback failed'
      )
      expect(
        lifecycle.begin_reconciliation(
          start.run_id,
          source: 'daemon_restart'
        )
      ).to be_nil

      recovery = lifecycle.begin_reconciliation(
        start.run_id,
        source: 'state_recovery'
      )
      expect(recovery).not_to be_nil
      expect(
        lifecycle.commit_reconciliation(start.run_id, recovery)
      ).to be(true)
      expect(
        lifecycle.claim_reconciliation_state_effects(
          start.run_id,
          recovery,
          :running
        )
      ).to be(false)
      lifecycle.finish_reconciliation(start.run_id, recovery)
    end
  end

  it 'lets explicit recovery clear taint after all runtime generations are gone' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      lease = lifecycle.begin_policy_update(kind: :cpuset_cpus)
      lifecycle.finish_policy_update(
        lease.id,
        error: 'write failed',
        rollback_error: 'rollback failed'
      )

      expect(
        lifecycle.clear_policy_taint_after_recovery(
          policy_root_removed: false
        )
      ).to be(false)
      expect(
        lifecycle.clear_policy_taint_after_recovery(
          policy_root_removed: true
        )
      ).to be(true)
      expect(lifecycle.policy_tainted?).to be(false)
      expect(lifecycle.snapshot.dig('policy', 'recovery'))
        .to match(/explicit recovery/)
    end
  end

  it 'lets only one caller claim a start effect and makes duplicates join it' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      effect_id = lifecycle.claim_effect(request.run_id, :start)

      expect(effect_id).not_to be_nil
      expect(lifecycle.claim_effect(request.run_id, :start)).to be_nil

      duplicate = lifecycle.request_start

      expect(duplicate.action).to eq(:join)
      expect(duplicate.run_id).to eq(request.run_id)
      expect(duplicate.intent_id).to eq(request.intent_id)
      expect(duplicate.revision).to eq(lifecycle.revision)

      revision = lifecycle.revision
      lifecycle.request_start
      expect(lifecycle.revision).to eq(revision)
    end
  end

  it 'owns stopped lxc-execute as a transient generation without changing intent' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_execution

      expect(request.action).to eq(:launch)
      expect(lifecycle.desired_state).to eq(:stopped)
      expect(lifecycle.current_intent_id).to be_nil
      expect(lifecycle.run(request.run_id)).to include(
        'kind' => 'execution',
        'phase' => 'preparing'
      )
      expect(
        lifecycle.run(request.run_id).dig('resources', 'wrapper_cgroup')
      ).to end_with(
        "/runs/#{request.run_id.key}/user-owned/wrapper"
      )

      duplicate = lifecycle.request_execution
      expect(duplicate.action).to eq(:wait)
      expect(duplicate.run_id).to eq(request.run_id)
    end
  end

  it 'serializes a normal start behind a transient execution generation' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      execution = lifecycle.request_execution
      effect_id = lifecycle.claim_effect(execution.run_id, :execute)

      lifecycle.mark_execution_launching(
        execution.run_id,
        effect_id,
        Process.pid
      )
      expect(
        lifecycle.authorize_lxc_start(execution.run_id, Process.pid)
      ).to be(false)
      expect(
        lifecycle.authorize_lxc_execution(execution.run_id, Process.pid)
      ).to be(true)
      lifecycle.activate_lxc_start(execution.run_id, Process.pid)
      callback_id = lifecycle.begin_callback(
        execution.run_id,
        name: 'CtPreStart'
      )
      expect(
        lifecycle.consume_pre_start(
          execution.run_id,
          client_pid: Process.pid,
          callback_id:
        )
      ).to be(true)
      expect(
        lifecycle.complete_pre_start(execution.run_id, callback_id:)
      ).to eq([true, effect_id])
      lifecycle.finish_callback(execution.run_id, callback_id)

      lifecycle.observe_state(
        execution.run_id,
        :running,
        init_pid: Process.pid
      )
      stop = lifecycle.request_stop
      expect(stop.action).to eq(:stop)

      start = lifecycle.request_start
      expect(start.action).to eq(:wait)
      expect(lifecycle.desired_state).to eq(:running)

      lifecycle.observe_wrapper_gone(execution.run_id)
      cleanup_effect = lifecycle.observe_post_stop(execution.run_id)
      _completed, restart_intent_id =
        lifecycle.complete_run(execution.run_id, cleanup_effect)

      expect(restart_intent_id).to eq(start.intent_id)
      replacement = lifecycle.request_start(
        source: 'reconcile',
        expected_intent_id: restart_intent_id
      )
      expect(replacement.action).to eq(:launch)
      expect(lifecycle.run(replacement.run_id)).to include(
        'kind' => 'container'
      )
    end
  end

  it 'attaches only to a stable normal running generation' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, effect_id)

      process_id = lifecycle.register_attachment(
        start.run_id,
        pid: Process.pid
      )
      expect(process_id).to be_a(String)
      expect(lifecycle.manipulation_blocker).to include(processes: 1)

      expect(lifecycle.finish_process(start.run_id, process_id)).to be(false)
      expect(lifecycle.run(start.run_id).fetch('processes')).to be_empty
      expect(lifecycle.manipulation_blocker).to be_nil

      lifecycle.request_stop
      expect(
        lifecycle.register_attachment(start.run_id, pid: Process.pid)
      ).to be_nil
    end
  end

  it 'never interrupts a running generation manager to drain a hook child' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.mark_launching(start.run_id, effect_id, Process.pid)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, effect_id)

      read_io, write_io = IO.pipe
      child_pid = Process.fork do
        write_io.close
        read_io.read
      end
      read_io.close

      begin
        allow(lifecycle).to receive(:watch_process)
        lifecycle.register_process(
          start.run_id,
          kind: 'hook:post_start',
          pid: child_pid
        )

        expect(lifecycle.daemon_restart_blockers).not_to be_empty
        expect(
          lifecycle.daemon_restart_processes(start.run_id).map do |identity|
            identity.fetch('pid')
          end
        ).to eq([child_pid])
      ensure
        write_io.close
        Process.wait(child_pid)
      end
    end
  end

  it 'tracks an external command child without racing its live supervisor' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, effect_id)
      process_id = lifecycle.register_attachment(
        start.run_id,
        pid: Process.pid
      )
      expect(
        lifecycle.handoff_attachment(
          start.run_id,
          process_id,
          pid: Process.pid
        )
      ).to be(true)

      read_io, write_io = IO.pipe
      child_pid = Process.fork do
        write_io.close
        read_io.read
      end
      read_io.close

      begin
        expect(
          lifecycle.handoff_attachment_child(
            start.run_id,
            process_id,
            pid: Process.pid,
            child_pid:
          )
        ).to be(true)
        process = lifecycle.run(start.run_id)
                           .fetch('processes')
                           .fetch(process_id)
        expect(process).to include(
          'external_stage' => 'child',
          'supervisor' => hash_including('pid' => Process.pid),
          'identity' => hash_including('pid' => child_pid)
        )
        expect(lifecycle.manipulation_blocker).to include(processes: 1)

        write_io.close
        Process.wait(child_pid)
        child_pid = nil

        expect(
          lifecycle.send(
            :finish_dead_process,
            start.run_id,
            process_id,
            process.fetch('identity')
          )
        ).to eq([false, nil, nil])
        expect(
          lifecycle.finish_external_attachment(
            start.run_id,
            process_id,
            pid: Process.pid
          )
        ).to eq([true, false])
      ensure
        write_io.close unless write_io.closed?
        if child_pid
          Process.kill('KILL', child_pid)
          Process.wait(child_pid)
        end
      end
    end
  end

  it 'resumes finalization when the last running attachment exits' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, start_effect)
      process_id = lifecycle.register_attachment(
        start.run_id,
        pid: Process.pid
      )

      expect(lifecycle.observe_post_stop(start.run_id)).to be(false)
      expect(lifecycle.observe_wrapper_gone(start.run_id)).to be(false)
      expect(lifecycle.finish_process(start.run_id, process_id))
        .to be_a(String)
      expect(lifecycle.active_phase).to eq(:cleaning)
    end
  end

  it 'restores a normal running intent after a failed stop' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, start_effect)

      stop = lifecycle.request_stop
      stop_effect = lifecycle.claim_effect(stop.run_id, :stop)
      lifecycle.fail_stop(stop.run_id, stop_effect, 'injected failure')

      expect(lifecycle.desired_state).to eq(:running)
      expect(lifecycle.manipulation_blocker).to be_nil

      retry_stop = lifecycle.request_stop
      expect(retry_stop.action).to eq(:stop)
      expect(retry_stop.intent_id).not_to eq(stop.intent_id)
    end
  end

  it 'preserves a stop intent interrupted by daemon restart' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, start_effect)

      stop = lifecycle.request_stop
      stop_effect = lifecycle.claim_effect(stop.run_id, :stop)
      prepare_restart_interruption(lifecycle, stop.run_id, stop_effect)
      lifecycle.fail_stop(stop.run_id, stop_effect, 'restart interruption')

      expect(lifecycle.desired_state).to eq(:stopped)
      expect(lifecycle.daemon_restart_blockers).to be_empty

      retry_stop = lifecycle.request_stop(
        expected_intent_id: stop.intent_id,
        source: 'daemon-restart'
      )
      expect(retry_stop.action).to eq(:stop)
      expect(lifecycle.claim_effect(retry_stop.run_id, :stop)).not_to be_nil
      expect(lifecycle.run(stop.run_id)).not_to have_key(
        'daemon_restart_handoff'
      )
    end
  end

  it 'preserves a start intent interrupted by daemon restart' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      prepare_restart_interruption(lifecycle, start.run_id, effect_id)

      lifecycle.fail_launch(start.run_id, effect_id, 'restart interruption')

      expect(lifecycle.desired_state).to eq(:running)
      expect(lifecycle.current_intent_id).to eq(start.intent_id)
      expect(lifecycle.daemon_restart_blockers).to be_empty

      retry_start = lifecycle.request_start(
        expected_intent_id: start.intent_id,
        source: 'daemon-restart'
      )
      expect(retry_start.action).to eq(:launch)
      expect(retry_start.run_id).not_to eq(start.run_id)
    end
  end

  it 'clears interrupted start handoff after running recovery completes' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      prepare_restart_interruption(lifecycle, start.run_id, effect_id)
      observer_id = lifecycle.begin_state_observation(
        start.run_id,
        :running,
        init_pid: Process.pid,
        source: 'monitor'
      )
      expect(
        lifecycle.claim_state_effects(start.run_id, observer_id, :running)
      ).to be(true)

      expect(
        lifecycle.complete_running_effects(start.run_id, observer_id)
      ).to be(true)
      lifecycle.finish_state_observation(start.run_id, observer_id)
      lifecycle.finish_effect(start.run_id, effect_id)

      expect(lifecycle.run(start.run_id)).not_to have_key(
        'daemon_restart_handoff'
      )
      expect(lifecycle.desired_state).to eq(:running)
      expect(lifecycle.daemon_restart_blockers).to be_empty
    end
  end

  it 'hands interrupted cleanup to daemon restart recovery' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.finish_effect(start.run_id, start_effect)
      lifecycle.observe_wrapper_gone(start.run_id)
      cleanup_effect = lifecycle.observe_post_stop(start.run_id)
      prepare_restart_interruption(lifecycle, start.run_id, cleanup_effect)

      lifecycle.fail_cleanup(
        start.run_id,
        cleanup_effect,
        'restart interruption'
      )

      expect(lifecycle.desired_state).to eq(:stopped)
      expect(lifecycle.active_phase).to eq(:cleanup_failed)
      expect(lifecycle.daemon_restart_blockers).to be_empty
    end
  end

  it 'waits for an interrupted effect worker to leave before handoff' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, start_effect)
      stop = lifecycle.request_stop
      stop_effect = lifecycle.claim_effect(stop.run_id, :stop)
      child_pid = Process.spawn('sleep', '30')
      allow(lifecycle).to receive(:watch_process)
      process_id = lifecycle.register_process(
        stop.run_id,
        kind: 'hook:test',
        pid: child_pid
      )
      worker_ready = Queue.new
      reduce = Queue.new
      reduced = Queue.new
      finish = Queue.new
      worker = Thread.new do
        lifecycle.set_effect_worker(stop.run_id, stop_effect, Process.pid)
        worker_ready << true
        reduce.pop
        lifecycle.fail_stop(
          stop.run_id,
          stop_effect,
          'restart interruption'
        )
        reduced << true
        finish.pop
        lifecycle.effect_worker_exited(stop.run_id, stop_effect)
      end
      worker_ready.pop

      processes = lifecycle.interrupt_daemon_restart_effect(
        stop.run_id,
        expected_effect_id: stop_effect,
        expected_phase: lifecycle.run(stop.run_id).fetch('phase'),
        signal: 'TERM'
      )
      expect(processes.map { |v| v.fetch('pid') }).to include(child_pid)
      Process.wait(child_pid)
      child_pid = nil
      lifecycle.finish_process(stop.run_id, process_id)
      reduce << true
      reduced.pop

      expect(lifecycle.daemon_restart_blockers).to contain_exactly(
        include(
          run_id: stop.run_id.to_s,
          workers: contain_exactly(
            include('kind' => 'restart_interrupted_effect')
          )
        )
      )

      finish << true
      worker.join
      expect(lifecycle.daemon_restart_blockers).to be_empty
    ensure
      finish << true if worker&.alive?
      worker&.join
      if child_pid
        Process.kill('KILL', child_pid)
        Process.wait(child_pid)
      end
    end
  end

  it 'resumes a restart whose stop is interrupted by daemon restart' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, start_effect)
      restart = lifecycle.request_restart
      stop = lifecycle.request_stop(expected_intent_id: restart.intent_id)
      stop_effect = lifecycle.claim_effect(stop.run_id, :stop)
      prepare_restart_interruption(lifecycle, stop.run_id, stop_effect)

      lifecycle.fail_stop(stop.run_id, stop_effect, 'restart interruption')

      run = lifecycle.run(stop.run_id)
      expect(lifecycle.desired_state).to eq(:running)
      expect(lifecycle.current_intent_id).to eq(restart.intent_id)
      expect(run.fetch('launch_intent_id')).to eq(start.intent_id)
      expect(lifecycle.daemon_restart_blockers).to be_empty

      retry_stop = lifecycle.request_stop(
        expected_intent_id: restart.intent_id,
        source: 'daemon-restart'
      )
      retry_effect = lifecycle.claim_effect(retry_stop.run_id, :stop)
      lifecycle.finish_effect(retry_stop.run_id, retry_effect)
      lifecycle.observe_wrapper_gone(retry_stop.run_id)
      cleanup_effect = lifecycle.observe_post_stop(retry_stop.run_id)
      completed, restart_intent_id = lifecycle.complete_run(
        retry_stop.run_id,
        cleanup_effect
      )

      expect(completed).to be(true)
      expect(restart_intent_id).to eq(restart.intent_id)
      retry_start = lifecycle.request_start(
        expected_intent_id: restart_intent_id,
        source: 'daemon-restart'
      )
      expect(retry_start.action).to eq(:launch)
    end
  end

  it 'resumes an interrupted start after its published wrapper exits' do
    with_tmpdir do |root|
      ct = build_container(root)
      lifecycle = described_class.new(ct)
      ct.define_singleton_method(:lifecycle) { lifecycle }
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.set_effect_worker(start.run_id, effect_id, Process.pid)
      wrapper_pid = Process.spawn('sleep', '30')
      lifecycle.mark_launching(start.run_id, effect_id, wrapper_pid)
      processes = lifecycle.interrupt_daemon_restart_effect(
        start.run_id,
        expected_effect_id: effect_id,
        expected_phase: 'launching',
        signal: 'TERM'
      )
      expect(processes.map { |v| v.fetch('pid') }).to include(wrapper_pid)
      Process.wait(wrapper_pid)
      wrapper_pid = nil
      recovery_class = stub_const(
        'OsCtld::Container::Recovery',
        Class.new do
          def initialize(*); end

          def recover_state(*); end
        end
      )
      recovery = instance_double(recovery_class, recover_state: {})
      allow(recovery_class).to receive(:new)
        .with(ct)
        .and_return(recovery)
      command = OsCtld::Commands::Container::Start.new({}, {})

      command.send(
        :finish_dead_wrapper,
        ct,
        double,
        start.run_id,
        effect_id
      )
      lifecycle.effect_worker_exited(start.run_id, effect_id)
      cleanup_effect = lifecycle.observe_post_stop(start.run_id)
      completed, restart_intent_id = lifecycle.complete_run(
        start.run_id,
        cleanup_effect
      )

      expect(recovery).to have_received(:recover_state).with(run_id: start.run_id)
      expect(completed).to be(true)
      expect(lifecycle.desired_state).to eq(:running)
      expect(restart_intent_id).to eq(lifecycle.current_intent_id)
      expect(restart_intent_id).not_to eq(start.intent_id)
    ensure
      if wrapper_pid
        Process.kill('KILL', wrapper_pid)
        Process.wait(wrapper_pid)
      end
    end
  end

  it 'preserves a managed start interrupted after its effect is released' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.mark_launching(start.run_id, effect_id, Process.pid)
      lifecycle.authorize_lxc_start(start.run_id, Process.pid)
      lifecycle.activate_lxc_start(start.run_id, Process.pid)
      callback_id = lifecycle.begin_callback(
        start.run_id,
        name: 'CtPreStart'
      )
      lifecycle.consume_pre_start(
        start.run_id,
        client_pid: Process.pid,
        callback_id:
      )
      lifecycle.complete_pre_start(start.run_id, callback_id:)
      lifecycle.finish_callback(start.run_id, callback_id)
      child_pid = Process.spawn('sleep', '30')
      signalled_pid = child_pid
      allow(lifecycle).to receive(:watch_process)
      process_id = lifecycle.register_process(
        start.run_id,
        kind: 'hook:test',
        pid: child_pid
      )

      expect(lifecycle.run(start.run_id)).to include(
        'phase' => 'starting',
        'effect' => nil
      )
      processes = lifecycle.interrupt_daemon_restart_effect(
        start.run_id,
        expected_effect_id: nil,
        expected_phase: 'starting',
        signal: 'TERM'
      )
      Process.wait(child_pid)
      child_pid = nil
      lifecycle.finish_process(start.run_id, process_id)
      expect(lifecycle.run(start.run_id).fetch('daemon_restart_handoff'))
        .to include(
          'effect_type' => 'start',
          'effect_missing' => true
        )

      lifecycle.observe_wrapper_gone(start.run_id)
      cleanup_effect = lifecycle.observe_post_stop(start.run_id)

      expect(processes.map { |v| v.fetch('pid') }).to include(signalled_pid)
      expect(lifecycle.desired_state).to eq(:running)
      expect(lifecycle.current_intent_id).not_to eq(start.intent_id)
      expect(lifecycle.complete_run(start.run_id, cleanup_effect))
        .to eq([true, lifecycle.current_intent_id])
    ensure
      if child_pid
        Process.kill('KILL', child_pid)
        Process.wait(child_pid)
      end
    end
  end

  it 'rejects stale effect interruption without marking replacement work' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, start_effect)
      first_stop = lifecycle.request_stop
      first_effect = lifecycle.claim_effect(first_stop.run_id, :stop)
      lifecycle.fail_stop(first_stop.run_id, first_effect, 'ordinary failure')
      second_stop = lifecycle.request_stop
      second_effect = lifecycle.claim_effect(second_stop.run_id, :stop)
      child_pid = Process.spawn('sleep', '30')
      allow(lifecycle).to receive(:watch_process)
      lifecycle.register_process(
        second_stop.run_id,
        kind: 'hook:test',
        pid: child_pid
      )

      expect(
        lifecycle.interrupt_daemon_restart_effect(
          second_stop.run_id,
          expected_effect_id: first_effect,
          expected_phase: 'running',
          signal: 'TERM'
        )
      ).to be_nil
      effect = lifecycle.run(second_stop.run_id).fetch('effect')
      expect(effect).to include('id' => second_effect)
      expect(effect).not_to have_key('daemon_restart_interrupted')
      expect { Process.kill(0, child_pid) }.not_to raise_error
    ensure
      if child_pid
        Process.kill('KILL', child_pid)
        Process.wait(child_pid)
      end
    end
  end

  it 'keeps the exact effect locked until its signal is delivered' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      child_pid = Process.spawn('sleep', '30')
      signalled_pid = child_pid
      allow(lifecycle).to receive(:watch_process)
      lifecycle.register_process(
        start.run_id,
        kind: 'hook:test',
        pid: child_pid
      )
      transition_attempted = Queue.new
      transition = nil
      allow(Process).to receive(:kill).and_wrap_original do |original, *args|
        if args == ['TERM', child_pid]
          transition = Thread.new do
            transition_attempted << true
            lifecycle.fail_launch(
              start.run_id,
              effect_id,
              'concurrent completion'
            )
          end
          transition_attempted.pop
          expect(lifecycle.instance_variable_get(:@mutex)).to be_owned
          expect(transition).to be_alive
        end
        original.call(*args)
      end

      processes = lifecycle.interrupt_daemon_restart_effect(
        start.run_id,
        expected_effect_id: effect_id,
        expected_phase: 'preparing',
        signal: 'TERM'
      )
      Process.wait(child_pid)
      child_pid = nil
      transition.join

      expect(processes.map { |v| v.fetch('pid') }).to include(signalled_pid)
      expect(lifecycle.desired_state).to eq(:running)
    ensure
      transition&.join
      if child_pid
        Process.kill('KILL', child_pid)
        Process.wait(child_pid)
      end
    end
  end

  it 'retains completed cleanup ownership through persisted restart handoff' do
    with_tmpdir do |root|
      ct = build_container(root)
      lifecycle = described_class.new(ct)
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, start_effect)
      restart = lifecycle.request_restart
      stop = lifecycle.request_stop(expected_intent_id: restart.intent_id)
      stop_effect = lifecycle.claim_effect(stop.run_id, :stop)
      lifecycle.finish_effect(stop.run_id, stop_effect)
      lifecycle.observe_wrapper_gone(stop.run_id)
      cleanup_effect = lifecycle.observe_post_stop(stop.run_id)
      ready = Queue.new
      completed = Queue.new
      finish = Queue.new
      worker = Thread.new do
        lifecycle.set_effect_worker(stop.run_id, cleanup_effect, Process.pid)
        ready << true
        completed << lifecycle.complete_run(stop.run_id, cleanup_effect)
        finish.pop
        lifecycle.effect_worker_exited(stop.run_id, cleanup_effect)
      end
      ready.pop
      expect(completed.pop).to eq([true, restart.intent_id])

      restored = described_class.new(ct)
      run_conf = instance_double(
        OsCtld::Container::RunConfiguration,
        run_id: stop.run_id
      )
      expect(restored.active_run_id).to be_nil
      expect(restored.desired_state).to eq(:running)
      expect(restored.run(stop.run_id).fetch('effect')).to include(
        'id' => cleanup_effect,
        'status' => 'completed'
      )
      expect(restored.daemon_restart_blockers).to contain_exactly(
        include(
          run_id: stop.run_id.to_s,
          workers: contain_exactly(include('kind' => 'completed_effect'))
        )
      )
      expect(restored.adopt_legacy(run_conf, :error)).to eq(
        :uncertain_completed
      )
      expect(restored.desired_state).to eq(:running)
      expect(restored.adopt_legacy(run_conf, :stopped)).to eq(
        :stale_completed
      )
      expect(restored.desired_state).to eq(:running)

      finish << true
      worker.join
      worker = nil
      expect(described_class.new(ct).daemon_restart_blockers).to be_empty
    ensure
      finish << true if worker&.alive?
      worker&.join
    end
  end

  it 'preserves clean restart handoff after post-completion failure' do
    with_tmpdir do |root|
      ct = build_container(root)
      lifecycle = described_class.new(ct)
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.finish_effect(start.run_id, start_effect)
      restart = lifecycle.request_restart
      stop = lifecycle.request_stop(expected_intent_id: restart.intent_id)
      stop_effect = lifecycle.claim_effect(stop.run_id, :stop)
      lifecycle.finish_effect(stop.run_id, stop_effect)
      lifecycle.observe_wrapper_gone(stop.run_id)
      cleanup_effect = lifecycle.observe_post_stop(stop.run_id)
      failed = Queue.new
      finish = Queue.new
      worker = Thread.new do
        lifecycle.set_effect_worker(stop.run_id, cleanup_effect, Process.pid)
        lifecycle.complete_run(stop.run_id, cleanup_effect)
        failed << lifecycle.fail_cleanup(
          stop.run_id,
          cleanup_effect,
          'run configuration removal failed'
        )
        finish.pop
        lifecycle.effect_worker_exited(stop.run_id, cleanup_effect)
      end
      expect(failed.pop).to be(true)

      run = lifecycle.run(stop.run_id)
      expect(run).to include(
        'role' => 'history',
        'phase' => 'clean',
        'post_completion_error' => 'run configuration removal failed'
      )
      expect(run.fetch('effect')).to include(
        'id' => cleanup_effect,
        'status' => 'completed',
        'post_completion_error' => 'run configuration removal failed'
      )
      expect(lifecycle.desired_state).to eq(:running)
      expect(lifecycle.current_intent_id).to eq(restart.intent_id)
      expect(lifecycle.daemon_restart_blockers).to contain_exactly(
        include(
          run_id: stop.run_id.to_s,
          workers: contain_exactly(include('kind' => 'completed_effect'))
        )
      )

      finish << true
      worker.join
      worker = nil
      restored = described_class.new(ct)
      run_conf = instance_double(
        OsCtld::Container::RunConfiguration,
        run_id: stop.run_id
      )
      expect(restored.adopt_legacy(run_conf, :stopped)).to eq(
        :stale_completed
      )
      expect(restored.desired_state).to eq(:running)
    ensure
      finish << true if worker&.alive?
      worker&.join
    end
  end

  it 'does not turn a failed transient stop into a normal start intent' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      execution = lifecycle.request_execution
      launch_effect = lifecycle.claim_effect(execution.run_id, :execute)
      lifecycle.observe_state(
        execution.run_id,
        :running,
        init_pid: Process.pid
      )
      lifecycle.finish_effect(execution.run_id, launch_effect)

      stop = lifecycle.request_stop
      stop_effect = lifecycle.claim_effect(stop.run_id, :stop)
      lifecycle.fail_stop(stop.run_id, stop_effect, 'injected failure')

      expect(lifecycle.desired_state).to eq(:stopped)
      expect(lifecycle.request_stop.action).to eq(:stop)
    end
  end

  it 'consumes managed pre-start authorization once for the lxc-start tree' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      effect_id = lifecycle.claim_effect(request.run_id, :start)
      lifecycle.mark_launching(request.run_id, effect_id, Process.pid)

      expect(
        lifecycle.authorize_lxc_start(request.run_id, Process.pid)
      ).to be(true)
      expect(
        lifecycle.activate_lxc_start(request.run_id, Process.pid)
      ).to be(true)
      callback_id = lifecycle.begin_callback(
        request.run_id,
        name: 'CtPreStart'
      )
      expect(
        lifecycle.consume_pre_start(
          request.run_id,
          client_pid: Process.pid,
          callback_id:
        )
      ).to be(true)
      expect(
        lifecycle.consume_pre_start(
          request.run_id,
          client_pid: Process.pid,
          callback_id:
        )
      ).to be(false)
      expect(
        lifecycle.complete_pre_start(request.run_id, callback_id:)
      ).to eq([true, effect_id])
      lifecycle.finish_callback(request.run_id, callback_id)
    end
  end

  it 'rejects same-uid launch authorization outside the wrapper ancestry' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      effect_id = lifecycle.claim_effect(request.run_id, :start)
      wrapper_pid = Process.spawn('sleep', '10')

      begin
        lifecycle.mark_launching(request.run_id, effect_id, wrapper_pid)

        expect(
          lifecycle.authorize_lxc_start(request.run_id, Process.pid)
        ).to be(false)
      ensure
        Process.kill('KILL', wrapper_pid)
        Process.wait(wrapper_pid)
      end
    end
  end

  it 'keeps recovery fenced until an exact effect worker is gone' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      effect_id = lifecycle.claim_effect(request.run_id, :start)
      ready = Queue.new
      finish = Queue.new
      worker = Thread.new do
        lifecycle.set_effect_worker(request.run_id, effect_id, Process.pid)
        ready << true
        finish.pop
        lifecycle.effect_worker_exited(request.run_id, effect_id)
      end
      ready.pop

      first_lease = lifecycle.begin_recovery(request.run_id)

      expect(first_lease.blocking_workers).to include(
        hash_including('kind' => 'effect', 'id' => effect_id)
      )
      expect(first_lease.superseded_effect).to be_nil
      expect(lifecycle.effect_current?(request.run_id, effect_id)).to be(false)
      lifecycle.park_recovery(request.run_id, first_lease.id)

      finish << true
      worker.join

      second_lease = lifecycle.begin_recovery(request.run_id)

      expect(second_lease.blocking_workers).to be_empty
      expect(second_lease.superseded_effect).to include('id' => effect_id)
    end
  end

  it 'fences restart work when a newer stop intent wins' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      lifecycle.claim_effect(start.run_id, :start)
      restart = lifecycle.request_restart

      expect(restart.effect_id).not_to be_nil

      lifecycle.request_stop
      stale = lifecycle.request_start(
        source: 'restart',
        expected_intent_id: restart.effect_id
      )

      expect(stale.action).to eq(:superseded)
      expect(lifecycle.desired_state).to eq(:stopped)
    end
  end

  it 'rejects an exact recovery restart after its running intent is stopped' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      running = lifecycle.request_start(source: 'runtime-network-recovery')

      expect(lifecycle.running_intent_id).to eq(running.intent_id)

      lifecycle.request_stop(source: 'external')
      stale = lifecycle.request_restart(
        source: 'runtime-network-recovery',
        expected_intent_id: running.intent_id
      )

      expect(stale.action).to eq(:superseded)
      expect(lifecycle.desired_state).to eq(:stopped)
      expect(lifecycle.running_intent_id).to be_nil
    end
  end

  it 'claims finalization only after post-stop and wrapper exit are both observed' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      effect_id = lifecycle.claim_effect(request.run_id, :start)
      lifecycle.finish_effect(request.run_id, effect_id)

      expect(lifecycle.observe_wrapper_gone(request.run_id)).to be(false)

      cleanup_effect = lifecycle.observe_post_stop(request.run_id)

      expect(cleanup_effect).to be_a(String)
      expect(lifecycle.active_phase).to eq(:cleaning)
    end
  end

  it 'claims finalization when a stop effect releases after both observations' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      start_effect = lifecycle.claim_effect(request.run_id, :start)
      lifecycle.finish_effect(request.run_id, start_effect)
      lifecycle.observe_state(request.run_id, :running, init_pid: Process.pid)
      lifecycle.request_stop
      stop_effect = lifecycle.claim_effect(request.run_id, :stop)

      expect(lifecycle.observe_wrapper_gone(request.run_id)).to be(false)
      expect(lifecycle.observe_post_stop(request.run_id)).to be(false)

      lifecycle.finish_effect(request.run_id, stop_effect)

      expect(lifecycle.claim_finalization(request.run_id)).to be_a(String)
      expect(lifecycle.active_phase).to eq(:cleaning)
    end
  end

  it 'claims finalization when a start effect releases after both observations' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      start_effect = lifecycle.claim_effect(request.run_id, :start)

      expect(lifecycle.observe_wrapper_gone(request.run_id)).to be(false)
      expect(lifecycle.observe_post_stop(request.run_id)).to be(false)
      expect(lifecycle.finish_effect(request.run_id, start_effect)).to be(true)

      expect(lifecycle.claim_finalization(request.run_id)).to be_a(String)
      expect(lifecycle.active_phase).to eq(:cleaning)
    end
  end

  it 'blocks recovery while exact callbacks and hook children can publish effects' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      callback_id = lifecycle.begin_callback(
        request.run_id,
        name: 'VethUp'
      )
      process_id = lifecycle.register_process(
        request.run_id,
        kind: 'hook:pre_start',
        pid: Process.pid
      )

      lease = lifecycle.begin_recovery(request.run_id)

      expect(lease.blocking_workers).to include(
        hash_including('kind' => 'callback', 'id' => callback_id),
        hash_including('kind' => 'process', 'id' => process_id)
      )
      expect(
        lifecycle.record_network_interface(
          request.run_id,
          name: 'eth0',
          type: :routed,
          veth: 'veth123',
          routes: { '4' => ['192.0.2.1/32'] },
          callback_id:
        )
      ).to be(true)
      expect(
        lifecycle.record_network_interface(
          request.run_id,
          name: 'eth1',
          type: :routed,
          veth: 'veth456',
          routes: {},
          callback_id: 'unknown'
        )
      ).to be(false)
      expect(
        lifecycle.run(request.run_id)
                 .dig('resources', 'network_interfaces', 'eth0')
      ).to include('veth' => 'veth123')
      lifecycle.park_recovery(request.run_id, lease.id)
      lifecycle.finish_callback(request.run_id, callback_id)
      lifecycle.finish_process(request.run_id, process_id)

      retry_lease = lifecycle.begin_recovery(request.run_id)
      expect(retry_lease.blocking_workers).to be_empty
    end
  end

  it 'blocks cleanup while exact state reconciliation is running' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      reconciliation_id = lifecycle.begin_reconciliation(
        request.run_id,
        source: 'wrapper'
      )

      lease = lifecycle.begin_recovery(request.run_id)

      expect(lease.blocking_workers).to include(
        hash_including(
          'kind' => 'reconciliation',
          'id' => reconciliation_id
        )
      )
    end
  end

  it 'supersedes a reconciliation worker lost with the old daemon' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      stale_id = lifecycle.begin_reconciliation(
        request.run_id,
        source: 'daemon_restart'
      )
      stale_worker = lifecycle.run(request.run_id)
                              .fetch('reconciliation')
                              .fetch('worker')
      dead_worker = instance_double(OsCtld::ProcessIdentity, alive?: false)

      allow(OsCtld::ProcessIdentity).to receive(:load)
        .with(stale_worker)
        .and_return(dead_worker)

      replacement_id = lifecycle.begin_reconciliation(
        request.run_id,
        source: 'daemon_restart'
      )

      expect(replacement_id).to be_a(String)
      expect(replacement_id).not_to eq(stale_id)
      expect(lifecycle.run(request.run_id).fetch('hazards'))
        .to include("superseded stale reconciliation #{stale_id}")
    end
  end

  it 'runs an exact callback while asking read-only reconciliation to yield' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      reconciliation_id = lifecycle.begin_reconciliation(
        request.run_id,
        source: 'daemon_restart'
      )
      revision = lifecycle.revision
      result = Queue.new
      release = Queue.new

      callback = Thread.new do
        callback_id = lifecycle.begin_callback(
          request.run_id,
          name: 'ct_post_stop'
        )
        result << callback_id
        release.pop
        lifecycle.finish_callback(request.run_id, callback_id)
      end

      expect(lifecycle.wait_for_change(revision, timeout: 1)).to be(true)
      callback_id = result.pop
      expect(lifecycle.run(request.run_id).dig('callbacks', callback_id))
        .to include('status' => 'running')
      expect(
        lifecycle.commit_reconciliation(
          request.run_id,
          reconciliation_id
        )
      ).to be(false)

      release << true
      callback.join
      lifecycle.finish_reconciliation(request.run_id, reconciliation_id)
    end
  end

  it 'waits an exact callback behind exclusive reconciliation' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      reconciliation_id = lifecycle.begin_reconciliation(
        request.run_id,
        source: 'daemon_restart'
      )
      lifecycle.commit_reconciliation(request.run_id, reconciliation_id)
      revision = lifecycle.revision
      result = Queue.new
      release = Queue.new

      callback = Thread.new do
        callback_id = lifecycle.begin_callback(
          request.run_id,
          name: 'ct_post_stop'
        )
        result << callback_id
        release.pop
        lifecycle.finish_callback(request.run_id, callback_id)
      end

      expect(lifecycle.wait_for_change(revision, timeout: 1)).to be(true)
      expect(lifecycle.run(request.run_id).fetch('callbacks').values)
        .to include(hash_including('status' => 'waiting'))
      expect(result).to be_empty

      lifecycle.finish_reconciliation(request.run_id, reconciliation_id)
      callback_id = result.pop

      expect(callback_id).to be_a(String)
      expect(lifecycle.run(request.run_id).dig('callbacks', callback_id))
        .to include('status' => 'running')
      release << true
      callback.join
    end
  end

  it 'rejects monitor observation admission during reconciliation' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      lifecycle.begin_reconciliation(
        request.run_id,
        source: 'daemon_restart'
      )

      observer_id = lifecycle.begin_state_observation(
        request.run_id,
        :running,
        init_pid: Process.pid
      )

      expect(observer_id).to be_nil
      expect(lifecycle.run(request.run_id).fetch('observations')).not_to be_empty
    end
  end

  it 'claims unreported running effects from exclusive reconciliation' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      reconciliation_id = lifecycle.begin_reconciliation(
        request.run_id,
        source: 'daemon_restart'
      )

      expect(
        lifecycle.commit_reconciliation(
          request.run_id,
          reconciliation_id
        )
      ).to be(true)
      expect(
        lifecycle.claim_reconciliation_state_effects(
          request.run_id,
          reconciliation_id,
          :running
        )
      ).to be(true)
      expect(
        lifecycle.claim_reconciliation_state_effects(
          request.run_id,
          reconciliation_id,
          :running
        )
      ).to be(false)

      lifecycle.complete_running_effects(
        request.run_id,
        reconciliation_id
      )

      expect(lifecycle.run(request.run_id)).to include(
        'reported_state' => 'running',
        'running_effects_started' => true,
        'running_effects_done' => true
      )
    end
  end

  it 'persists post-stop hook completion only for the current cleanup effect' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      start_effect = lifecycle.claim_effect(request.run_id, :start)
      lifecycle.finish_effect(request.run_id, start_effect)
      lifecycle.observe_wrapper_gone(request.run_id)
      cleanup_effect = lifecycle.observe_post_stop(request.run_id)
      lifecycle.claim_finalizer_hook(
        request.run_id,
        cleanup_effect,
        'post_stop'
      )

      expect(
        lifecycle.complete_post_stop_hook(
          request.run_id,
          'stale-effect',
          error: nil
        )
      ).to be(false)
      expect(
        lifecycle.complete_post_stop_hook(
          request.run_id,
          cleanup_effect,
          error: 'hook failed'
        )
      ).to be(true)
      expect(lifecycle.run(request.run_id)).to include(
        'post_stop_hook_done' => true,
        'post_stop_hook_error' => 'hook failed'
      )
    end
  end

  it 'quarantines a residual, releases the slot, and fences its late events' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      first = lifecycle.request_start
      effect_id = lifecycle.claim_effect(first.run_id, :start)

      lease = lifecycle.begin_recovery(first.run_id)
      effect, intent_id = lifecycle.quarantine(
        first.run_id,
        recovery_id: lease.id,
        evidence: { 'survivors' => [{ 'pid' => 123 }] },
        hazards: ['already-entered kernel I/O may complete later']
      )

      expect(lease.superseded_effect.fetch('id')).to eq(effect_id)
      expect(effect).to be_nil
      expect(intent_id).to be_nil
      expect(lifecycle.observe_wrapper_gone(first.run_id)).to be(false)

      execution = lifecycle.request_execution
      expect(execution.action).to eq(:blocked)
      expect(
        lifecycle.begin_parent_policy_update(kind: :group_cpuset)
      ).to be_nil
      cpu_policy = lifecycle.begin_parent_policy_update(
        kind: :group_cpu_bandwidth,
        allow_residuals: true
      )
      expect(cpu_policy).not_to be_nil
      lifecycle.finish_parent_policy_update(cpu_policy.id)

      second = lifecycle.request_start

      expect(second.action).to eq(:launch)
      expect(second.run_id).not_to eq(first.run_id)
      expect(second.warning).to include('1 residual container generation')
      expect(lifecycle.residuals.length).to eq(1)
      expect(lifecycle.other_runtime_generation?(first.run_id)).to be(true)
      expect(lifecycle.other_runtime_generation?(second.run_id)).to be(true)
    end
  end

  it 'quarantines failed historical cleanup without changing current intent' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      failed = lifecycle.request_start
      effect_id = lifecycle.claim_effect(failed.run_id, :start)
      lifecycle.fail_launch(failed.run_id, effect_id, 'launch failed')

      lease = lifecycle.begin_recovery(failed.run_id)
      effect, intent_id = lifecycle.quarantine(
        failed.run_id,
        recovery_id: lease.id,
        evidence: { 'cgroup_error' => 'resource busy' },
        hazards: ['generation resources could not be removed']
      )

      expect(effect).to be_nil
      expect(intent_id).to be_nil
      expect(lifecycle.active_run_id).to be_nil
      expect(lifecycle.desired_state).to eq(:stopped)
      expect(lifecycle.run(failed.run_id)).to include(
        'role' => 'residual',
        'phase' => 'quarantined'
      )
      expect(lifecycle.residuals.map { |run| run.fetch('id') })
        .to include(failed.run_id.dump)
    end
  end

  it 'does not restart a normally halted run without a newer intent' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.finish_effect(start.run_id, start_effect)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.observe_wrapper_gone(start.run_id)

      cleanup_effect = lifecycle.observe_post_stop(start.run_id, reboot: false)
      completed, restart_intent_id =
        lifecycle.complete_run(start.run_id, cleanup_effect)

      expect(completed).to be(true)
      expect(restart_intent_id).to be_nil
      expect(lifecycle.desired_state).to eq(:stopped)
    end
  end

  it 'ends start waits when a generation stops before reaching running' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.finish_effect(start.run_id, start_effect)
      lifecycle.observe_wrapper_gone(start.run_id)
      cleanup_effect = lifecycle.observe_post_stop(start.run_id)
      lifecycle.complete_run(start.run_id, cleanup_effect)

      expect(lifecycle.wait_for_start(start.run_id)).to eq(:clean)
    end
  end

  it 'turns an in-container reboot into a new running intent' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.finish_effect(start.run_id, start_effect)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.observe_wrapper_gone(start.run_id)

      cleanup_effect = lifecycle.observe_post_stop(start.run_id, reboot: true)
      completed, restart_intent_id =
        lifecycle.complete_run(start.run_id, cleanup_effect)

      expect(completed).to be(true)
      expect(restart_intent_id).not_to eq(start.intent_id)
      expect(restart_intent_id).to eq(lifecycle.current_intent_id)
      expect(lifecycle.desired_state).to eq(:running)
    end
  end

  it 'coalesces an external start with an in-container reboot' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.finish_effect(start.run_id, start_effect)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)
      lifecycle.observe_state(start.run_id, :stopping)

      external = lifecycle.request_start(source: 'external')
      expect(external.action).to eq(:wait)
      expect(external.intent_id).not_to eq(start.intent_id)

      lifecycle.observe_wrapper_gone(start.run_id)
      cleanup_effect = lifecycle.observe_post_stop(start.run_id, reboot: true)
      _completed, restart_intent_id =
        lifecycle.complete_run(start.run_id, cleanup_effect)

      expect(restart_intent_id).to eq(external.intent_id)

      replacement = lifecycle.request_start(
        source: 'reconcile',
        expected_intent_id: restart_intent_id
      )
      duplicate = lifecycle.request_start(
        source: 'external',
        expected_intent_id: external.intent_id
      )

      expect(replacement.action).to eq(:launch)
      expect(duplicate.run_id).to eq(replacement.run_id)
      expect(duplicate.action).to eq(:launch)
    end
  end

  it 'cancels an unlaunched run without touching a later generation' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start
      lifecycle.request_stop

      expect(lifecycle.active_run_id).to be_nil
      expect(lifecycle.run(request.run_id).fetch('phase')).to eq('clean')
      expect(
        lifecycle.cancel_unlaunched(request.run_id, 'cancelled during reconciliation')
      ).to be(false)
    end
  end

  it 'can cancel an operator-cleared queued start and its desired state atomically' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      request = lifecycle.request_start(source: 'queued')

      expect(
        lifecycle.cancel_unlaunched(
          request.run_id,
          'queue cancelled',
          preserve_desired: false,
          source: 'autostart-cancel'
        )
      ).to be(true)
      expect(lifecycle.active_run_id).to be_nil
      expect(lifecycle.desired_state).to eq(:stopped)
      expect(lifecycle.run(request.run_id).fetch('phase')).to eq('clean')
    end
  end

  it 'does not let a waiting start reassert itself after a newer stop' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      lifecycle.claim_effect(
        start.run_id,
        :start,
        expected_intent_id: start.intent_id
      )

      stop = lifecycle.request_stop
      stale = lifecycle.request_start(expected_intent_id: start.intent_id)

      expect(stop.intent_id).not_to eq(start.intent_id)
      expect(stale.action).to eq(:superseded)
      expect(lifecycle.desired_state).to eq(:stopped)
    end
  end

  it 'retains a newer start intent when a superseded launch fails' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      first = lifecycle.request_start
      effect_id = lifecycle.claim_effect(
        first.run_id,
        :start,
        expected_intent_id: first.intent_id
      )
      lifecycle.mark_launching(first.run_id, effect_id, Process.pid)
      lifecycle.request_stop
      replacement = lifecycle.request_start

      expect(replacement.action).to eq(:wait)
      expect(
        lifecycle.fail_launch(first.run_id, effect_id, 'superseded')
      ).to be(true)
      expect(lifecycle.desired_state).to eq(:running)
      expect(lifecycle.current_intent_id).to eq(replacement.intent_id)

      retry_request = lifecycle.request_start(
        expected_intent_id: replacement.intent_id
      )
      expect(retry_request.action).to eq(:launch)
      expect(retry_request.run_id).not_to eq(first.run_id)
    end
  end

  it 'keeps stop behind normal launch until exact pre-start completes' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(
        start.run_id,
        :start,
        expected_intent_id: start.intent_id
      )
      lifecycle.mark_launching(start.run_id, effect_id, Process.pid)
      lifecycle.authorize_lxc_start(start.run_id, Process.pid)
      lifecycle.activate_lxc_start(start.run_id, Process.pid)

      stop = lifecycle.request_stop
      expect(stop.action).to eq(:wait)
      expect(lifecycle.finish_effect(start.run_id, effect_id)).to be(false)
      expect(
        lifecycle.request_stop(expected_intent_id: stop.intent_id).action
      ).to eq(:wait)

      callback_id = lifecycle.begin_callback(start.run_id, name: 'CtPreStart')
      lifecycle.consume_pre_start(
        start.run_id,
        client_pid: Process.pid,
        callback_id:
      )
      expect(
        lifecycle.request_stop(expected_intent_id: stop.intent_id).action
      ).to eq(:wait)
      expect(
        lifecycle.complete_pre_start(start.run_id, callback_id:)
      ).to eq([true, effect_id])
      expect(
        lifecycle.wait_for_launch_handoff(start.run_id, effect_id)
      ).to eq(:complete)
      lifecycle.finish_callback(start.run_id, callback_id)

      ready = lifecycle.request_stop(expected_intent_id: stop.intent_id)

      expect(ready.action).to eq(:stop)
      expect(ready.run_id).to eq(start.run_id)
    end
  end

  it 'keeps stop behind stopped execution until exact pre-start completes' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      execution = lifecycle.request_execution
      effect_id = lifecycle.claim_effect(execution.run_id, :execute)
      lifecycle.mark_execution_launching(
        execution.run_id,
        effect_id,
        Process.pid
      )
      lifecycle.authorize_lxc_execution(execution.run_id, Process.pid)
      lifecycle.activate_lxc_start(execution.run_id, Process.pid)

      stop = lifecycle.request_stop
      expect(stop.action).to eq(:wait)
      expect(lifecycle.finish_effect(execution.run_id, effect_id)).to be(false)

      callback_id = lifecycle.begin_callback(
        execution.run_id,
        name: 'CtPreStart'
      )
      lifecycle.consume_pre_start(
        execution.run_id,
        client_pid: Process.pid,
        callback_id:
      )
      expect(
        lifecycle.request_stop(expected_intent_id: stop.intent_id).action
      ).to eq(:wait)
      expect(
        lifecycle.complete_pre_start(execution.run_id, callback_id:)
      ).to eq([true, effect_id])
      lifecycle.finish_callback(execution.run_id, callback_id)

      ready = lifecycle.request_stop(expected_intent_id: stop.intent_id)
      expect(ready.action).to eq(:stop)
      expect(ready.run_id).to eq(execution.run_id)
    end
  end

  it 'lets a committed stop proceed when a newer start requests replacement' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.finish_effect(start.run_id, start_effect)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)

      stop = lifecycle.request_stop
      replacement = lifecycle.request_start
      stop_effect = lifecycle.claim_effect(stop.run_id, :stop)

      expect(replacement.action).to eq(:wait)
      expect(stop_effect).to be_a(String)
      expect(lifecycle.run(start.run_id).dig('effect', 'type')).to eq('stop')
    end
  end

  it 'records but does not apply late state events from a residual generation' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      first = lifecycle.request_start
      lease = lifecycle.begin_recovery(first.run_id)
      lifecycle.quarantine(
        first.run_id,
        recovery_id: lease.id,
        evidence: {},
        hazards: ['residual']
      )

      lifecycle.observe_state(first.run_id, :running, init_pid: Process.pid)

      residual = lifecycle.run(first.run_id)
      expect(residual.fetch('phase')).to eq('quarantined')
      expect(residual.dig('observations', 'monitor', 'state')).to eq('running')
    end
  end

  it 'wakes lifecycle waiters when exact cleanup fails' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      start_effect = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.finish_effect(start.run_id, start_effect)
      lifecycle.observe_wrapper_gone(start.run_id)
      cleanup_effect = lifecycle.observe_post_stop(start.run_id)

      expect(
        lifecycle.fail_cleanup(start.run_id, cleanup_effect, 'cleanup broke')
      ).to be(true)
      expect(lifecycle.wait_for_start(start.run_id)).to eq(:cleanup_failed)
      expect(lifecycle.wait_for_stop(start.run_id)).to eq(:cleanup_failed)

      request = lifecycle.request_start
      expect(request.action).to eq(:failed)
    end
  end

  it 'does not block daemon restart for a stable running generation' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start
      effect_id = lifecycle.claim_effect(start.run_id, :start)
      lifecycle.finish_effect(start.run_id, effect_id)
      lifecycle.observe_state(start.run_id, :running, init_pid: Process.pid)

      expect(lifecycle.daemon_restart_blockers).to be_empty
    end
  end

  it 'reports an unlaunched durable start as a daemon restart blocker' do
    with_tmpdir do |root|
      lifecycle = described_class.new(build_container(root))
      start = lifecycle.request_start(source: 'autostart')

      expect(lifecycle.daemon_restart_blockers).to contain_exactly(
        include(
          type: 'container_generation',
          run_id: start.run_id.to_s,
          phase: 'preparing'
        )
      )
    end
  end
end
