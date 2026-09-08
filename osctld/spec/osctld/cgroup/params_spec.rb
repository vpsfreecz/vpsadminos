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
  let(:cgroup_state) { Struct.new(:version, :set_param_calls).new(2, []) }

  before do
    OsCtl::Lib::Logger.setup(:none)
    state = cgroup_state
    allow(OsCtld::CGroup).to receive(:version) { state.version }
    allow(OsCtld::CGroup).to receive(:v1?) { state.version == 1 }
    allow(OsCtld::CGroup).to receive(:v2?) { state.version == 2 }
    allow(OsCtld::CGroup).to receive(:real_subsystem) { |subsystem| subsystem }
    allow(OsCtld::CGroup).to receive(:abs_cgroup_path) do |subsystem, path = nil|
      File.join(*['/sys/fs/cgroup', subsystem, path].compact)
    end
    allow(OsCtld::CGroup).to receive(:set_param) do |path, value|
      state.set_param_calls << [path, value]
      true
    end
    allow(File).to receive(:exist?).and_call_original
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

    expect(cgroup_state.set_param_calls).to include(
      ['/cg/memory/memory.max', [100_000, 50_000]],
      ['/cg/cpu/cpu.max', ['50000 100000']]
    )

    params.unset([{ subsystem: 'cpu', parameter: 'cpu.max', version: 2 }], reset: false)
    expect(params.detect { |p| p.name == 'cpu.max' }).to be_nil

    allow(params).to receive(:reset).and_call_original
    params.replace([param(2, 'memory', 'memory.high', [1])]) { |subsystem| File.join('/cg', subsystem) }
    expect(params).to have_received(:reset).with(instance_of(OsCtld::CGroup::Param), true)

    params.reset(param(2, 'memory', 'memory.max', [1]), false) { |subsystem| File.join('/cg', subsystem) }
    expect(cgroup_state.set_param_calls).to include(['/cg/memory/memory.max', ['max']])

    expect(params.dump).to eq([{ 'version' => 2, 'subsystem' => 'memory', 'name' => 'memory.high', 'value' => [1], 'persistent' => true }])

    copy = params.dup(owner)
    copy.detect { |p| p.name == 'memory.high' }.value << 2
    expect(params.detect { |p| p.name == 'memory.high' }.value).to eq([1])
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
