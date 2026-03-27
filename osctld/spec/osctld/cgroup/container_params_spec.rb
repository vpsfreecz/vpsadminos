# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/cgroup/param'
require 'osctld/cgroup/params'
require 'osctld/cgroup/container_params'

RSpec.describe OsCtld::CGroup::ContainerParams do
  def param(version, subsystem, name, value, persistent = true)
    OsCtld::CGroup::Param.new(version, subsystem, name, value, persistent)
  end

  let(:owner) do
    FakeObjects::FakeRuntimeContainer.new(
      pool: Struct.new(:name).new('tank'),
      id: 'ct1',
      running: true,
      lxc_config: FakeObjects::FakeLxcConfig.new
    )
  end
  let(:cgroup_state) { Struct.new(:version, :set_param_calls).new(2, []) }

  before do
    OsCtl::Lib::Logger.setup(:none)
    state = cgroup_state
    OsCtld::CGroup.define_singleton_method(:version) { state.version }
    OsCtld::CGroup.define_singleton_method(:v1?) { state.version == 1 }
    OsCtld::CGroup.define_singleton_method(:v2?) { state.version == 2 }
    OsCtld::CGroup.define_singleton_method(:set_param) do |path, value|
      state.set_param_calls << [path, value]
      true
    end
    OsCtld::CGroup.define_singleton_method(:set_param_calls) { state.set_param_calls }
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
      ['/sys/fs/cgroup/memory/ct.ct1/user-owned/lxc.payload.ct1/memory.max', [100_000]],
      ['/sys/fs/cgroup/memory/ct.ct1/memory.max', ['max']],
      ['/sys/fs/cgroup/memory/ct.ct1/user-owned/lxc.payload.ct1/memory.max', ['max']]
    )
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
      ['/sys/fs/cgroup/memory/ct.ct1/user-owned/lxc.payload.ct1/memory.limit_in_bytes', [150_000]],
      ['/sys/fs/cgroup/memory/ct.ct1/user-owned/lxc.payload.ct1/memory.memsw.limit_in_bytes', [150_000]]
    )

    cgroup_state.version = 2
    v2 = described_class.new(owner, params: [param(2, 'memory', 'memory.max', [100_000])])

    v2.temporarily_expand_memory(percent: 50)

    expect(OsCtld::CGroup.set_param_calls).to include(
      ['/sys/fs/cgroup/memory/ct.ct1/memory.max', [150_000]],
      ['/sys/fs/cgroup/memory/ct.ct1/user-owned/lxc.payload.ct1/memory.max', [150_000]]
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
