# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/cgroup/param'
require 'osctld/cgroup/params'

RSpec.describe OsCtld::CGroup::Params do
  def param(version, subsystem, name, value, persistent = true)
    OsCtld::CGroup::Param.new(version, subsystem, name, value, persistent)
  end

  around do |example|
    names = %i[version v1? v2? real_subsystem abs_cgroup_path set_param set_param_calls]
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

  let(:owner) { FakeObjects::FakeRuntimeContainer.new(pool: Struct.new(:name).new('tank'), id: 'ct1') }
  let(:cgroup_state) do
    Struct.new(:version, :set_param_calls, :rejected_writes)
          .new(2, [], [])
  end

  before do
    OsCtl::Lib::Logger.setup(:none)
    state = cgroup_state
    OsCtld::CGroup.define_singleton_method(:version) { state.version }
    OsCtld::CGroup.define_singleton_method(:v1?) { state.version == 1 }
    OsCtld::CGroup.define_singleton_method(:v2?) { state.version == 2 }
    OsCtld::CGroup.define_singleton_method(:real_subsystem) { |subsystem| subsystem }
    OsCtld::CGroup.define_singleton_method(:abs_cgroup_path) do |subsystem|
      File.join('/sys/fs/cgroup', subsystem)
    end
    OsCtld::CGroup.define_singleton_method(:set_param) do |path, value|
      state.set_param_calls << [path, value]
      !state.rejected_writes.include?([path, value])
    end
    OsCtld::CGroup.define_singleton_method(:set_param_calls) { state.set_param_calls }
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:read).and_wrap_original do |method, path, *args|
      if path.start_with?('/cg/') && File.basename(path) == 'cpuset.cpus'
        write = state.set_param_calls.reverse_each.detect do |set_path, _value|
          set_path == path
        end
        write ? write.last.last.to_s : ''
      else
        method.call(path, *args)
      end
    end
    allow(OsCtld::CGroup::CpusetPolicy)
      .to receive(:read_effective_mask)
      .and_wrap_original do |method, path|
        if path.start_with?('/cg/')
          write = state.set_param_calls.reverse_each.detect do |set_path, _value|
            set_path == File.join(path, 'cpuset.cpus')
          end
          if write
            OsCtl::Lib::CpuMask.new(write.last.last.to_s).to_s
          else
            '0-7'
          end
        else
          method.call(path)
        end
      end
  end

  it 'loads, imports, and validates parameters for the active cgroup version' do
    loaded = described_class.load(owner, [{ 'version' => 2, 'subsystem' => 'memory', 'name' => 'memory.max', 'value' => [100_000] }])
    allow(File).to receive(:exist?).with('/sys/fs/cgroup/memory/osctl/memory.max').and_return(true)

    imported = loaded.import(
      [
        {
          subsystem: 'memory',
          parameter: 'memory.max',
          value: [200_000],
          version: 2
        }
      ]
    )

    expect(imported.first.value).to eq([200_000])

    allow(File).to receive(:exist?).with('/sys/fs/cgroup/memory/osctl/memory.high').and_return(false)
    expect do
      loaded.import([{ subsystem: 'memory', parameter: 'memory.high', value: [1], version: 2 }])
    end.to raise_error(OsCtld::CGroupParameterNotFound)
  end

  it 'sets, appends, unsets, applies, replaces, resets, dumps, and duplicates params' do
    params = described_class.new(owner, params: [param(2, 'memory', 'memory.max', [100_000])])

    params.set([param(2, 'memory', 'memory.max', [50_000])], append: true)
    params.set([param(2, 'cpu', 'cpu.max', ['50000 100000'], false)])
    params.apply { |subsystem| File.join('/cg', subsystem) }

    expect(OsCtld::CGroup.set_param_calls).to include(
      ['/cg/memory/memory.max', [100_000, 50_000]],
      ['/cg/cpu/cpu.max', ['50000 100000']]
    )

    params.unset([{ subsystem: 'cpu', parameter: 'cpu.max', version: 2 }], reset: false)
    expect(params.detect { |p| p.name == 'cpu.max' }).to be_nil

    allow(params).to receive(:reset).and_call_original
    params.replace([param(2, 'memory', 'memory.high', [1])]) { |subsystem| File.join('/cg', subsystem) }
    expect(params).to have_received(:reset).with(instance_of(OsCtld::CGroup::Param), true)

    params.reset(param(2, 'memory', 'memory.max', [1]), false) { |subsystem| File.join('/cg', subsystem) }
    expect(OsCtld::CGroup.set_param_calls).to include(['/cg/memory/memory.max', ['max']])

    expect(params.dump).to eq([{ 'version' => 2, 'subsystem' => 'memory', 'name' => 'memory.high', 'value' => [1], 'persistent' => true }])

    copy = params.dup(owner)
    copy.detect { |p| p.name == 'memory.high' }.value << 2
    expect(params.detect { |p| p.name == 'memory.high' }.value).to eq([1])
  end

  it 'reports rejected group parameter writes' do
    path = '/cg/pids/pids.max'
    cgroup_state.rejected_writes << [path, [100]]
    params = described_class.new(
      owner,
      params: [param(2, 'pids', 'pids.max', [100])]
    )

    expect do
      params.apply { |subsystem| File.join('/cg', subsystem) }
    end.to raise_error(
      OsCtld::CGroup::CpusetPolicy::Error,
      /kernel rejected group cgroup parameters: pids.max/
    )
  end

  it 'applies only the configured cpuset when requested' do
    params = described_class.new(
      owner,
      params: [
        param(2, 'cpuset', 'cpuset.cpus', ['0-3']),
        param(2, 'pids', 'pids.max', [100])
      ]
    )

    params.apply(only_cpuset: true) do |subsystem|
      File.join('/cg', subsystem, 'group.app')
    end

    expect(OsCtld::CGroup.set_param_calls).to eq(
      [['/cg/cpuset/group.app/cpuset.cpus', ['0-3']]]
    )
  end

  it 'keeps group cpuset and CPU parameters out of generic writes' do
    group = OsCtld::Group.allocate
    params = described_class.new(
      group,
      params: [
        param(2, 'cpuset', 'cpuset.cpus', ['0-3']),
        param(2, 'cpu', 'cpu.max', ['50000 100000']),
        param(2, 'pids', 'pids.max', [100])
      ]
    )
    allow(group).to receive(:save_config)
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
    allow(OsCtld::CGroup::GroupCpusetPolicy).to receive(:new)

    params.apply(cpuset: false, cpu_bandwidth: false) do |subsystem|
      File.join('/cg', subsystem, 'group.app')
    end

    expect(OsCtld::CGroup.set_param_calls).to eq(
      [['/cg/pids/group.app/pids.max', [100]]]
    )
    expect(
      OsCtld::CGroup::GroupCpuBandwidthPolicy
    ).not_to have_received(:new)
    expect(OsCtld::CGroup::GroupCpusetPolicy).not_to have_received(:new)
  end

  it 'applies both group hierarchy policies before generic parameters' do
    group = OsCtld::Group.allocate
    params = described_class.new(
      group,
      params: [
        param(2, 'cpuset', 'cpuset.cpus', ['0-3']),
        param(2, 'cpu', 'cpu.max', ['50000 100000']),
        param(2, 'pids', 'pids.max', [100])
      ]
    )
    cpu_policy = instance_double(
      OsCtld::CGroup::GroupCpuBandwidthPolicy,
      apply: true
    )
    cpuset_policy = instance_double(
      OsCtld::CGroup::GroupCpusetPolicy,
      apply: true
    )
    calls = []
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
      .with(group, reconstruct_to: group, containers: nil)
      .and_return(cpu_policy)
    allow(OsCtld::CGroup::GroupCpusetPolicy).to receive(:new)
      .with(group, reconstruct_to: group)
      .and_return(cpuset_policy)
    allow(cpu_policy).to receive(:apply) { calls << :cpu }
    allow(cpuset_policy).to receive(:apply) { calls << :cpuset }
    allow(params).to receive(:verify_cpuset_path)
    allow(OsCtld::CGroup).to receive(:set_param) do |path, value|
      calls << [path, value]
      true
    end

    params.apply do |subsystem|
      File.join('/cg', subsystem, 'group.app')
    end

    expect(calls).to eq(
      [
        :cpu,
        :cpuset,
        ['/cg/pids/group.app/pids.max', [100]]
      ]
    )
  end

  it 'uses the exact CPU journal when a later group parameter write fails' do
    group = OsCtld::Group.allocate
    params = described_class.new(group)
    cpu = param(2, 'cpu', 'cpu.max', ['50000 100000'])
    pids = param(2, 'pids', 'pids.max', [100])
    cpu_result = instance_double(
      OsCtld::CGroup::CpuBandwidthPolicy::Result,
      rollback!: true
    )
    cpu_policy = instance_double(
      OsCtld::CGroup::GroupCpuBandwidthPolicy,
      apply: cpu_result
    )
    allow(group).to receive(:save_config)
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
      .with(group, reconstruct_to: group, containers: [])
      .and_return(cpu_policy)
    cgroup_state.rejected_writes << [
      '/cg/pids/group.app/pids.max',
      [100]
    ]

    expect do
      params.transactional_set(
        [cpu, pids],
        cpuset: false,
        policy_containers: []
      ) { |subsystem| File.join('/cg', subsystem, 'group.app') }
    end.to raise_error(
      OsCtld::CGroup::CpusetPolicy::Error,
      /kernel rejected group cgroup parameters: pids.max/
    )

    expect(cpu_result).to have_received(:rollback!).once
    expect(
      OsCtld::CGroup::GroupCpuBandwidthPolicy
    ).to have_received(:new).once
    expect(params.each.to_a).to be_empty
    expect(OsCtld::CGroup.set_param_calls).to include(
      ['/cg/pids/group.app/pids.max', [100]],
      ['/cg/pids/group.app/pids.max', ['max']]
    )
  end

  it 'passes removed v1 CPU components to the hierarchy policy as resets' do
    cgroup_state.version = 1
    group = OsCtld::Group.allocate
    quota = param(
      1,
      'cpu',
      OsCtld::CGroup::CpuBandwidthPolicy::QUOTA_PARAMETER,
      [250_000]
    )
    period = param(
      1,
      'cpu',
      OsCtld::CGroup::CpuBandwidthPolicy::PERIOD_PARAMETER,
      [200_000]
    )
    params = described_class.new(group, params: [quota, period])
    policy = instance_double(
      OsCtld::CGroup::GroupCpuBandwidthPolicy,
      apply: true
    )
    allow(group).to receive(:save_config)
    allow(OsCtld::CGroup::GroupCpuBandwidthPolicy).to receive(:new)
      .and_return(policy)

    params.transactional_unset(
      [quota.export],
      cpuset: false
    ) { |subsystem| File.join('/cg', subsystem, 'group.app') }

    expect(
      OsCtld::CGroup::GroupCpuBandwidthPolicy
    ).to have_received(:new).with(
      group,
      reconstruct_to: group,
      containers: nil,
      resets: contain_exactly(
        have_attributes(
          version: 1,
          name: OsCtld::CGroup::CpuBandwidthPolicy::QUOTA_PARAMETER
        )
      )
    )
    expect(params.each.map(&:name)).to eq(
      [OsCtld::CGroup::CpuBandwidthPolicy::PERIOD_PARAMETER]
    )
  end

  it 'resets a group cpuset to its effective parent mask' do
    params = described_class.new(owner)
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:read_effective_mask)
      .with('/cg/cpuset')
      .and_return('0-7')

    params.reset(
      param(2, 'cpuset', 'cpuset.cpus', ['2-3']),
      false
    ) { |subsystem| File.join('/cg', subsystem, 'group.app') }

    expect(OsCtld::CGroup.set_param_calls).to include(
      ['/cg/cpuset/group.app/cpuset.cpus', ['0-7']]
    )
    expect(OsCtld::CGroup.set_param_calls.flatten).not_to include('all')
  end

  it 'rejects a cpuset write whose effective mask remains narrower' do
    params = described_class.new(
      owner,
      params: [param(2, 'cpuset', 'cpuset.cpus', ['0-3'])]
    )
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:read_effective_mask)
      .with('/cg/cpuset/group.app')
      .and_return('0-1')

    expect do
      params.apply do |subsystem|
        File.join('/cg', subsystem, 'group.app')
      end
    end.to raise_error(
      OsCtld::CGroup::CpusetPolicy::Error,
      /requested="0-3", effective="0-1", expected="0-3"/
    )
  end

  it 'does not write staged runtime when durable configuration fails' do
    params = described_class.new(
      owner,
      params: [param(2, 'memory', 'memory.max', [100_000])]
    )
    saves = 0
    allow(owner).to receive(:save_config).and_wrap_original do |method|
      saves += 1
      raise 'injected config failure' if saves == 1

      method.call
    end
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:read_effective_mask)
      .with('/cg/cpuset')
      .and_return('0-7')

    expect do
      params.transactional_set(
        [
          param(2, 'cpuset', 'cpuset.cpus', ['2-3']),
          param(2, 'pids', 'pids.max', [100])
        ]
      ) { |subsystem| File.join('/cg', subsystem, 'group.app') }
    end.to raise_error(
      OsCtld::CGroup::CpusetPolicy::Error,
      /injected config failure/
    )

    expect(OsCtld::CGroup.set_param_calls).to contain_exactly(
      ['/cg/cpuset/group.app/cpuset.cpus', ['0-7']],
      ['/cg/pids/group.app/pids.max', ['max']],
      ['/cg/memory/group.app/memory.max', [100_000]]
    )
    expect(params.each.map(&:name)).to eq(['memory.max'])
    expect(saves).to eq(2)
  end

  it 'exports a rollback error when an added parameter cannot be reset' do
    params = described_class.new(owner)
    allow(owner).to receive(:save_config)
      .and_raise('injected config failure')
    cgroup_state.rejected_writes << [
      '/cg/pids/group.app/pids.max',
      ['max']
    ]
    allow(OsCtld::CGroup::CpusetPolicy).to receive(:read_effective_mask)
      .and_return('0-7')

    error =
      begin
        params.transactional_set(
          [
            param(2, 'cpuset', 'cpuset.cpus', ['2-3']),
            param(2, 'pids', 'pids.max', [100])
          ]
        ) { |subsystem| File.join('/cg', subsystem, 'group.app') }
        nil
      rescue OsCtld::CGroup::CpusetPolicy::Error => e
        e
      end

    expect(error).not_to be_nil
    expect(error.rollback_error).not_to be_nil
    expect(error.message).to match(/rollback failed/)
    expect(params.each.to_a).to be_empty
  end

  it 'never resets inactive-version parameters during replacement' do
    params = described_class.new(
      owner,
      params: [param(1, 'cpuset', 'cpuset.cpus', ['0-3'])]
    )

    params.replace([]) do |subsystem|
      File.join('/cg', subsystem, 'group.app')
    end

    expect(OsCtld::CGroup.set_param_calls).to be_empty
  end

  it 'finds memory, swap, and cpu limits for cgroup v2' do
    params = described_class.new(
      owner,
      params: [
        param(2, 'memory', 'memory.max', [200_000]),
        param(2, 'memory', 'memory.swap.max', [50_000]),
        param(2, 'cpu', 'cpu.max', ['50000 100000'])
      ]
    )

    expect(params.find_memory_limit).to eq(200_000)
    expect(params.find_swap_limit).to eq(50_000)
    expect(params.find_cpu_limit).to eq(50)
  end

  it 'finds memory, swap, and cpu limits for cgroup v1' do
    cgroup_state.version = 1
    params = described_class.new(
      owner,
      params: [
        param(1, 'memory', 'memory.limit_in_bytes', [200_000]),
        param(1, 'memory', 'memory.memsw.limit_in_bytes', [150_000]),
        param(1, 'cpu', 'cpu.cfs_quota_us', [50_000]),
        param(1, 'cpu', 'cpu.cfs_period_us', [100_000])
      ]
    )

    expect(params.find_memory_limit).to eq(150_000)
    expect(params.find_swap_limit).to eq(150_000)
    expect(params.find_cpu_limit).to eq(50)
  end
end
