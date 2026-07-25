# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/cgroup/param'
require 'osctld/cgroup/params'
require 'osctld/cgroup/container_params'
require 'osctld/container/lifecycle'

RSpec.describe OsCtld::CGroup::ContainerParams do
  def param(version, subsystem, name, value, persistent = true)
    OsCtld::CGroup::Param.new(version, subsystem, name, value, persistent)
  end

  around do |example|
    names = %i[version v1? v2? set_param set_param_calls]
    methods = names.to_h do |name|
      [name, OsCtld::CGroup.respond_to?(name) ? OsCtld::CGroup.method(name) : nil]
    end

    example.run
  ensure
    methods.each do |name, method|
      if method
        OsCtld::CGroup.define_singleton_method(name, method)
      elsif OsCtld::CGroup.respond_to?(name)
        OsCtld::CGroup.singleton_class.remove_method(name)
      end
    end
  end

  let(:owner) do
    FakeObjects::FakeRuntimeContainer.new(
      pool: Struct.new(:name).new('tank'),
      id: 'ct1',
      running: true,
      lxc_config: FakeObjects::FakeLxcConfig.new
    )
  end
  let(:cgroup_state) do
    Struct.new(:version, :set_param_calls, :rejected_paths)
          .new(2, [], [])
  end

  before do
    OsCtl::Lib::Logger.setup(:none)
    state = cgroup_state
    OsCtld::CGroup.define_singleton_method(:version) { state.version }
    OsCtld::CGroup.define_singleton_method(:v1?) { state.version == 1 }
    OsCtld::CGroup.define_singleton_method(:v2?) { state.version == 2 }
    OsCtld::CGroup.define_singleton_method(:set_param) do |path, value|
      state.set_param_calls << [path, value]
      !state.rejected_paths.include?(path)
    end
    OsCtld::CGroup.define_singleton_method(:set_param_calls) { state.set_param_calls }
    allow(OsCtld::CGroup).to receive(:mkpath)
  end

  it 'sets params and reconfigures lxc cgroup settings' do
    params = described_class.new(owner)

    params.set([param(2, 'memory', 'memory.max', [100_000])])

    expect(owner.save_config_calls).to eq(1)
    expect(owner.lxc_config.cgparam_calls).to eq(1)
  end

  it 'applies and resets params on both owner and payload cgroups when running' do
    params = described_class.new(owner, params: [param(2, 'memory', 'memory.max', [100_000])])

    params.apply { |subsystem| owner.abs_apply_cgroup_path(subsystem) }
    params.reset(param(2, 'memory', 'memory.max', [100_000]), false) { |subsystem| owner.abs_apply_cgroup_path(subsystem) }

    expect(OsCtld::CGroup.set_param_calls).to include(
      ['/sys/fs/cgroup/memory/ct.ct1/memory.max', [100_000]],
      ['/sys/fs/cgroup/osctl/pool.tank/ct.ct1/user-owned/lxc.payload.ct1/memory.max', [100_000]],
      ['/sys/fs/cgroup/memory/ct.ct1/memory.max', ['max']],
      ['/sys/fs/cgroup/osctl/pool.tank/ct.ct1/user-owned/lxc.payload.ct1/memory.max', ['max']]
    )
  end

  it 'applies cpusets through a fenced hierarchy transaction' do
    cpuset = param(2, 'cpuset', 'cpuset.cpus', ['2-4'])
    params = described_class.new(owner, params: [cpuset])
    lease = Struct.new(:id).new('lease-1')
    result = OsCtld::CGroup::CpusetPolicy::Result.new(
      target: '2-4',
      run_masks: { 'run-1' => '2-4' }
    )
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      begin_policy_update: lease,
      finish_policy_update: nil
    )
    policy = instance_double(
      OsCtld::CGroup::CpusetPolicy,
      apply: result
    )
    allow(owner).to receive(:lifecycle).and_return(lifecycle)
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:new)
      .with(owner, '2-4')
      .and_return(policy)

    params.apply { |subsystem| owner.abs_apply_cgroup_path(subsystem) }

    expect(OsCtld::CGroup::CpusetPolicy).to have_received(:new)
      .with(owner, '2-4')
    expect(lifecycle).to have_received(:finish_policy_update).with(
      'lease-1',
      target: '2-4',
      run_masks: { 'run-1' => '2-4' },
      error: nil,
      rollback_error: nil
    )
    expect(OsCtld::CGroup.set_param_calls).to be_empty
  end

  it 'never propagates non-cpuset parameters to payload/inner' do
    params = described_class.new(
      owner,
      params: [param(2, 'pids', 'pids.max', [100])]
    )

    params.apply { |subsystem| owner.abs_apply_cgroup_path(subsystem) }

    expect(OsCtld::CGroup.set_param_calls).to contain_exactly(
      ['/sys/fs/cgroup/pids/ct.ct1/pids.max', [100]],
      [
        '/sys/fs/cgroup/osctl/pool.tank/ct.ct1/user-owned/' \
        'lxc.payload.ct1/pids.max',
        [100]
      ]
    )
  end

  it 'rejects a failed non-cpuset runtime write during apply' do
    stable_path = '/sys/fs/cgroup/pids/ct.ct1/pids.max'
    cgroup_state.rejected_paths << stable_path
    params = described_class.new(
      owner,
      params: [param(2, 'pids', 'pids.max', [100])]
    )

    expect do
      params.apply(
        cpuset: false
      ) { |subsystem| owner.abs_apply_cgroup_path(subsystem) }
    end.to raise_error(
      OsCtld::CGroup::CpusetPolicy::Error,
      /kernel rejected stable container cgroup parameters: pids.max/
    )
  end

  it 'persists a staged cpuset only after the runtime transaction succeeds' do
    params = described_class.new(
      owner,
      params: [param(2, 'cpuset', 'cpuset.cpus', ['0,1'])]
    )
    lease = Struct.new(:id).new('lease-1')
    result = OsCtld::CGroup::CpusetPolicy::Result.new(
      target: '2,3',
      run_masks: {}
    )
    events = []
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      begin_policy_update: lease,
      finish_policy_update: nil
    )
    policy = instance_double(OsCtld::CGroup::CpusetPolicy)
    allow(policy).to receive(:apply) do
      events << :apply
      result
    end
    allow(owner).to receive(:lifecycle).and_return(lifecycle)
    allow(owner).to receive(:save_config).and_wrap_original do |method|
      events << :save
      method.call
    end
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:new)
      .with(owner, '2,3')
      .and_return(policy)

    params.transactional_set(
      [param(2, 'cpuset', 'cpuset.cpus', ['2,3'])],
      apply: false
    )

    expect(events).to eq(%i[apply save])
    expect(params.detect { |item| item.name == 'cpuset.cpus' }.value)
      .to eq(['2,3'])
    expect(owner.save_config_calls).to eq(1)
    expect(owner.lxc_config.cgparam_calls).to eq(1)
  end

  it 'restores staged configuration after a rejected cpuset transaction' do
    params = described_class.new(
      owner,
      params: [param(2, 'cpuset', 'cpuset.cpus', ['0,1'])]
    )
    lease = Struct.new(:id).new('lease-1')
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      begin_policy_update: lease,
      finish_policy_update: nil
    )
    policy = instance_double(OsCtld::CGroup::CpusetPolicy)
    allow(policy).to receive(:apply).and_raise(
      OsCtld::CGroup::CpusetPolicy::Error,
      'kernel rejected policy'
    )
    allow(owner).to receive(:lifecycle).and_return(lifecycle)
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:new)
      .with(owner, '2,3')
      .and_return(policy)

    expect do
      params.transactional_set(
        [param(2, 'cpuset', 'cpuset.cpus', ['2,3'])],
        apply: false
      )
    end.to raise_error(
      OsCtld::CGroup::CpusetPolicy::Error,
      /kernel rejected policy/
    )

    expect(params.detect { |item| item.name == 'cpuset.cpus' }.value)
      .to eq(['0,1'])
    expect(lifecycle).to have_received(:finish_policy_update).with(
      'lease-1',
      target: '2,3',
      run_masks: {},
      error: 'kernel rejected policy',
      rollback_error: nil
    )
    expect(owner.save_config_calls).to eq(1)
    expect(owner.lxc_config.cgparam_calls).to eq(1)
  end

  it 'records launch policy results against the exact generation' do
    cpuset = param(2, 'cpuset', 'cpuset.cpus', ['2-4'])
    params = described_class.new(owner, params: [cpuset])
    result = OsCtld::CGroup::CpusetPolicy::Result.new(
      target: '2-4',
      run_masks: { 'run-1' => '2-4' }
    )
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      begin_launch_policy: Struct.new(:id).new('launch-lease-1'),
      run: {
        'resources' => {
          'cgroup_root' => '/osctl/pool.tank/ct.ct1/runs/run-1'
        }
      },
      record_launch_policy: true
    )
    policy = instance_double(
      OsCtld::CGroup::CpusetPolicy,
      apply: result
    )
    allow(owner).to receive(:lifecycle).and_return(lifecycle)
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:new)
      .with(owner, '2-4')
      .and_return(policy)

    params.apply_cpuset_for_start(run_id: 'run-1')

    expect(lifecycle).to have_received(:record_launch_policy).with(
      'run-1',
      lease_id: 'launch-lease-1',
      target: '2-4',
      run_masks: { 'run-1' => '2-4' }
    )
    expect(OsCtld::CGroup).to have_received(:mkpath).with(
      'cpuset',
      ['', 'osctl', 'pool.tank', 'ct.ct1', 'runs', 'run-1'],
      leaf: false
    )
  end

  it 'durably records a launch-policy rollback failure' do
    cpuset = param(2, 'cpuset', 'cpuset.cpus', ['2-4'])
    params = described_class.new(owner, params: [cpuset])
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      begin_launch_policy: Struct.new(:id).new('launch-lease-1'),
      run: {
        'resources' => {
          'cgroup_root' => '/osctl/pool.tank/ct.ct1/runs/run-1'
        }
      },
      record_launch_policy: true
    )
    rollback_error = OsCtld::CGroup::CpusetPolicy::Error.new(
      'rollback write failed'
    )
    policy_error = OsCtld::CGroup::CpusetPolicy::Error.new(
      'policy write failed',
      rollback_error:
    )
    policy = instance_double(OsCtld::CGroup::CpusetPolicy)
    allow(policy).to receive(:apply).and_raise(policy_error)
    allow(owner).to receive(:lifecycle).and_return(lifecycle)
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:new)
      .with(owner, '2-4')
      .and_return(policy)

    expect do
      params.apply_cpuset_for_start(run_id: 'run-1')
    end.to raise_error(
      OsCtld::CGroup::CpusetPolicy::Error,
      'policy write failed'
    )

    expect(lifecycle).to have_received(:record_launch_policy).with(
      'run-1',
      lease_id: 'launch-lease-1',
      target: '2-4',
      error: 'policy write failed',
      rollback_error: 'rollback write failed'
    )
  end

  it 'taints a mixed transaction when strict runtime rollback fails' do
    memory_path = '/sys/fs/cgroup/memory/ct.ct1/memory.max'
    cgroup_state.rejected_paths << memory_path
    params = described_class.new(
      owner,
      params: [
        param(2, 'cpuset', 'cpuset.cpus', ['0,1']),
        param(2, 'memory', 'memory.max', [100_000])
      ]
    )
    lease = Struct.new(:id).new('lease-1')
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      begin_policy_update: lease,
      finish_policy_update: nil,
      policy_tainted?: false
    )
    policy = instance_double(
      OsCtld::CGroup::CpusetPolicy,
      apply: OsCtld::CGroup::CpusetPolicy::Result.new(
        target: '2,3',
        run_masks: {}
      )
    )
    allow(owner).to receive(:lifecycle).and_return(lifecycle)
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:new)
      .and_return(policy)

    expect do
      params.transactional_set(
        [
          param(2, 'cpuset', 'cpuset.cpus', ['2,3']),
          param(2, 'memory', 'memory.max', [200_000])
        ]
      ) { |subsystem| owner.abs_apply_cgroup_path(subsystem) }
    end.to raise_error(
      OsCtld::CGroup::CpusetPolicy::Error,
      /rollback failed/
    )

    expect(lifecycle).to have_received(:finish_policy_update).with(
      'lease-1',
      target: '2,3',
      run_masks: {},
      error: a_string_matching(/stable container cgroup/),
      rollback_error: a_string_matching(/stable container cgroup/)
    )
    expect(params.detect { |item| item.name == 'memory.max' }.value)
      .to eq([100_000])
  end

  it 'rejects an unsupported reset before a mixed cpuset replacement' do
    params = described_class.new(
      owner,
      params: [
        param(2, 'cpuset', 'cpuset.cpus', ['0,1']),
        param(2, 'io', 'io.max', ['8:0 rbps=1048576'])
      ]
    )

    allow(OsCtld::CGroup::CpusetPolicy).to receive(:new)
    expect do
      params.transactional_replace(
        [param(2, 'cpuset', 'cpuset.cpus', ['2,3'])]
      ) { |subsystem| owner.abs_apply_cgroup_path(subsystem) }
    end.to raise_error(
      OsCtld::CGroup::CpusetPolicy::Error,
      /no runtime reset value is known for io.max/
    )

    expect(params.each.map { |item| [item.name, item.value] }).to contain_exactly(
      ['cpuset.cpus', ['0,1']],
      ['io.max', ['8:0 rbps=1048576']]
    )
    expect(OsCtld::CGroup.set_param_calls).to be_empty
    expect(owner.save_config_calls).to eq(0)
    expect(OsCtld::CGroup::CpusetPolicy).not_to have_received(:new)
  end

  it 'resets a v1 CPU limit as one fenced hierarchy transaction' do
    cgroup_state.version = 1
    period = param(
      1,
      'cpu',
      OsCtld::CGroup::CpuBandwidthPolicy::PERIOD_PARAMETER,
      [250_000]
    )
    quota = param(
      1,
      'cpu',
      OsCtld::CGroup::CpuBandwidthPolicy::QUOTA_PARAMETER,
      [500_000]
    )
    params = described_class.new(owner, params: [period, quota])
    lease = Struct.new(:id).new('lease-1')
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      begin_policy_update: lease,
      finish_policy_update: nil,
      policy_tainted?: false,
      residuals: []
    )
    policy = instance_double(
      OsCtld::CGroup::CpuBandwidthPolicy,
      apply: OsCtld::CGroup::CpuBandwidthPolicy::Result.new(
        target: {
          'quota_us' => -1,
          'period_us' => 100_000
        }
      )
    )
    allow(owner).to receive(:lifecycle).and_return(lifecycle)
    allow(OsCtld::CGroup::CpuBandwidthPolicy).to receive(:new)
      .and_return(policy)

    params.transactional_unset(
      [period.export, quota.export]
    ) { |subsystem| owner.abs_apply_cgroup_path(subsystem) }

    expect(params.each.to_a).to be_empty
    expect(OsCtld::CGroup::CpuBandwidthPolicy).to have_received(:new).with(
      owner,
      contain_exactly(
        have_attributes(
          name: OsCtld::CGroup::CpuBandwidthPolicy::PERIOD_PARAMETER,
          value: [100_000]
        ),
        have_attributes(
          name: OsCtld::CGroup::CpuBandwidthPolicy::QUOTA_PARAMETER,
          value: [-1]
        )
      ),
      root: '/sys/fs/cgroup/cpu/ct.ct1'
    )
    expect(lifecycle).to have_received(:begin_policy_update).with(
      kind: :cpu_bandwidth
    )
    expect(lifecycle).to have_received(:finish_policy_update).with(
      'lease-1',
      target: [],
      run_masks: {},
      error: nil,
      rollback_error: nil
    )
  end

  it 'allows an unsupported reset when no runtime hierarchy exists' do
    stopped_owner = FakeObjects::FakeRuntimeContainer.new(
      pool: Struct.new(:name).new('tank'),
      id: 'ct1',
      running: false,
      lxc_config: FakeObjects::FakeLxcConfig.new
    )
    stopped_owner.lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      active_run_id: nil,
      residuals: [],
      policy_tainted?: false
    )
    params = described_class.new(
      stopped_owner,
      params: [
        param(2, 'cpuset', 'cpuset.cpus', ['0,1']),
        param(2, 'io', 'io.max', ['8:0 rbps=1048576'])
      ]
    )

    params.transactional_replace(
      [param(2, 'cpuset', 'cpuset.cpus', ['2,3'])]
    ) { |subsystem| stopped_owner.abs_apply_cgroup_path(subsystem) }

    expect(params.each.map { |item| [item.name, item.value] }).to eq(
      [['cpuset.cpus', ['2,3']]]
    )
    expect(OsCtld::CGroup.set_param_calls).to be_empty
    expect(stopped_owner.save_config_calls).to eq(1)
  end

  it 'removes inactive-version parameters without writing them at runtime' do
    params = described_class.new(
      owner,
      params: [
        param(2, 'memory', 'memory.max', [100_000]),
        param(1, 'pids', 'pids.max', [100]),
        param(1, 'cpuset', 'cpuset.cpus', ['0,1'])
      ]
    )
    allow(owner).to receive(:lifecycle).and_return(
      instance_double(
        OsCtld::Container::Lifecycle,
        policy_tainted?: false
      )
    )

    params.transactional_unset(
      [
        param(1, 'pids', 'pids.max', [100]).export,
        param(1, 'cpuset', 'cpuset.cpus', ['0,1']).export
      ]
    ) { |subsystem| owner.abs_apply_cgroup_path(subsystem) }

    expect(params.each.map { |item| [item.version, item.name] }).to eq(
      [[2, 'memory.max']]
    )
    expect(OsCtld::CGroup.set_param_calls).to be_empty
    expect(owner.save_config_calls).to eq(1)
  end

  it 'replaces mixed-version parameters using only the active cgroup version' do
    params = described_class.new(
      owner,
      params: [
        param(2, 'cpuset', 'cpuset.cpus', ['0,1']),
        param(1, 'pids', 'pids.max', [100]),
        param(1, 'cpuset', 'cpuset.cpus', ['0,1'])
      ]
    )
    lease = Struct.new(:id).new('lease-1')
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      begin_policy_update: lease,
      finish_policy_update: nil,
      policy_tainted?: false
    )
    policy = instance_double(
      OsCtld::CGroup::CpusetPolicy,
      apply: OsCtld::CGroup::CpusetPolicy::Result.new(
        target: '2,3',
        run_masks: {}
      )
    )
    allow(owner).to receive(:lifecycle).and_return(lifecycle)
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:new)
      .with(owner, '2,3')
      .and_return(policy)

    params.transactional_replace(
      [param(2, 'cpuset', 'cpuset.cpus', ['2,3'])]
    ) { |subsystem| owner.abs_apply_cgroup_path(subsystem) }

    expect(params.each.map { |item| [item.version, item.name, item.value] })
      .to eq([[2, 'cpuset.cpus', ['2,3']]])
    expect(OsCtld::CGroup.set_param_calls).to be_empty
    expect(owner.save_config_calls).to eq(1)
  end

  it 'intersects a scheduler reset mask with the effective parent' do
    owner.run_conf = Struct.new(:cpu_package).new(1)
    params = described_class.new(owner)
    allow(OsCtld::CpuScheduler).to receive(:package_mask)
      .with(1)
      .and_return('0-5')
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:parent_mask)
      .with(owner)
      .and_return('2-7')

    expect(params.send(:default_cpuset_target)).to eq('2-5')
  end

  it 'temporarily expands memory on cgroup v1 and v2' do
    v1 = described_class.new(
      owner,
      params: [
        param(1, 'memory', 'memory.limit_in_bytes', [100_000]),
        param(1, 'memory', 'memory.memsw.limit_in_bytes', [100_000])
      ]
    )
    cgroup_state.version = 1

    v1.temporarily_expand_memory(percent: 50)

    expect(OsCtld::CGroup.set_param_calls).to include(
      ['/sys/fs/cgroup/memory/ct.ct1/memory.limit_in_bytes', [150_000]],
      ['/sys/fs/cgroup/memory/ct.ct1/memory.memsw.limit_in_bytes', [150_000]],
      ['/sys/fs/cgroup/memory/osctl/pool.tank/ct.ct1/user-owned/lxc.payload.ct1/memory.limit_in_bytes', [150_000]],
      ['/sys/fs/cgroup/memory/osctl/pool.tank/ct.ct1/user-owned/lxc.payload.ct1/memory.memsw.limit_in_bytes', [150_000]]
    )

    cgroup_state.version = 2
    v2 = described_class.new(owner, params: [param(2, 'memory', 'memory.max', [100_000])])

    v2.temporarily_expand_memory(percent: 50)

    expect(OsCtld::CGroup.set_param_calls).to include(
      ['/sys/fs/cgroup/memory/ct.ct1/memory.max', [150_000]],
      ['/sys/fs/cgroup/osctl/pool.tank/ct.ct1/user-owned/lxc.payload.ct1/memory.max', [150_000]]
    )
  end

  it 'does nothing for stopped containers' do
    owner.running = false
    params = described_class.new(owner, params: [param(2, 'memory', 'memory.max', [100_000])])

    params.apply { |subsystem| owner.abs_apply_cgroup_path(subsystem) }
    params.reset(param(2, 'memory', 'memory.max', [100_000]), false) { |subsystem| owner.abs_apply_cgroup_path(subsystem) }
    params.temporarily_expand_memory(percent: 50)

    expect(OsCtld::CGroup.set_param_calls).to eq(
      [
        ['/sys/fs/cgroup/memory/ct.ct1/memory.max', [100_000]],
        ['/sys/fs/cgroup/memory/ct.ct1/memory.max', ['max']]
      ]
    )
  end
end
