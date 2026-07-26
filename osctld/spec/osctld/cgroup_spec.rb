# frozen_string_literal: true

require 'stringio'
require 'osctld/exceptions'
require 'osctld/run_state'
require 'osctld/cgroup'

RSpec.describe OsCtld::CGroup do
  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  around do |example|
    version = described_class.instance_variable_get(:@version)
    subsystems = described_class.instance_variable_get(:@subsystems)
    described_class.instance_variable_set(:@version, nil)
    described_class.instance_variable_set(:@subsystems, nil)
    example.run
  ensure
    described_class.instance_variable_set(:@version, version)
    described_class.instance_variable_set(:@subsystems, subsystems)
  end

  def set_cgroup_version(version)
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(OsCtld::RunState::CGROUP_VERSION).and_return("#{version}\n")
  end

  def stub_missing_cgroup_version
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(OsCtld::RunState::CGROUP_VERSION).and_raise(Errno::ENOENT)
  end

  def force_cgroup(version, subsystems)
    described_class.instance_variable_set(:@version, version)
    described_class.instance_variable_set(:@subsystems, subsystems)
  end

  it 'defaults to cgroup v1 when the version file is missing' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtld::CGroup::FS', tmpdir)
      stub_missing_cgroup_version
      allow(Dir).to receive(:entries).with(tmpdir).and_return(%w[. .. cpu])

      described_class.init

      expect(described_class.version).to eq(1)
      expect(described_class.subsystems).to eq(['cpu'])
    end
  end

  it 'clamps invalid cgroup versions to v1' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtld::CGroup::FS', tmpdir)
      allow(Dir).to receive(:entries).with(tmpdir).and_return(%w[. .. cpu])
      set_cgroup_version(99)

      described_class.init

      expect(described_class.version).to eq(1)
    end
  end

  it 'maps shared subsystem mountpoints' do
    expect(described_class.real_subsystem('cpu')).to eq('cpu,cpuacct')
    expect(described_class.real_subsystem('cpuacct')).to eq('cpu,cpuacct')
    expect(described_class.real_subsystem('net_cls')).to eq('net_cls,net_prio')
    expect(described_class.real_subsystem('memory')).to eq('memory')
  end

  it 'builds v1 and v2 absolute cgroup paths' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtld::CGroup::FS', tmpdir)

      allow(Dir).to receive(:entries).with(tmpdir).and_return(%w[. .. cpu,cpuacct])
      set_cgroup_version(1)
      described_class.init
      expect(described_class.abs_cgroup_path('cpu', 'osctl', 'ct.ct1')).to eq(
        File.join(tmpdir, 'cpu,cpuacct', 'osctl', 'ct.ct1')
      )

      set_cgroup_version(2)
      described_class.init
      expect(described_class.abs_cgroup_path('cpu', 'osctl', 'ct.ct1')).to eq(
        File.join(tmpdir, 'osctl', 'ct.ct1')
      )
    end
  end

  it 'treats cgroups without cgroup.procs as missing' do
    with_tmpdir do |tmpdir|
      path = File.join(tmpdir, 'osctl', 'ct.ct1')
      FileUtils.mkdir_p(path)

      expect(described_class.exist?(path)).to be(false)

      File.write(File.join(path, 'cgroup.procs'), '')

      expect(described_class.exist?(path)).to be(true)
    end
  end

  it 'creates nested cgroups and reports whether the leaf was newly created' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtld::CGroup::FS', tmpdir)
      force_cgroup(1, ['cpu,cpuacct'])
      FileUtils.mkdir_p(File.join(tmpdir, 'cpu,cpuacct'))
      allow(described_class).to receive(:init_cgroup)

      expect(described_class.mkpath('cpu', %w[osctl ct.ct1], leaf: false)).to be(true)
      expect(Dir.exist?(File.join(tmpdir, 'cpu,cpuacct', 'osctl', 'ct.ct1'))).to be(true)

      expect(described_class.mkpath('cpu', %w[osctl ct.ct1], leaf: false)).to be(false)
    end
  end

  it 'forwards leaf and other options in mkpath_all' do
    allow(described_class).to receive(:subsystems).and_return(%w[cpu memory])
    allow(described_class).to receive(:mkpath)

    described_class.mkpath_all(%w[osctl ct.ct1], leaf: false, attach: true, pid: 123)

    expect(described_class).to have_received(:mkpath).with(
      'cpu',
      %w[osctl ct.ct1],
      chown: nil,
      attach: true,
      leaf: false,
      pid: 123,
      debug: false
    )
    expect(described_class).to have_received(:mkpath).with(
      'memory',
      %w[osctl ct.ct1],
      chown: nil,
      attach: true,
      leaf: false,
      pid: 123,
      debug: false
    )
  end

  it 'swallows EEXIST and initializes created cgroups only once' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtld::CGroup::FS', tmpdir)
      force_cgroup(2, [''])
      allow(described_class).to receive(:delegate_available_controllers)
      allow(described_class).to receive(:init_cgroup)
      cgroup = File.join(tmpdir, 'osctl')

      expect(described_class.create(cgroup, delegate: true, type: '', base: tmpdir)).to be(true)
      expect(described_class.create(cgroup, delegate: true, type: '', base: tmpdir)).to be(false)
      expect(described_class).to have_received(:delegate_available_controllers).once.with(cgroup)
      expect(described_class).to have_received(:init_cgroup).once.with('', tmpdir, cgroup)
    end
  end

  it 'delegates existing cgroup v2 paths when leaf is false' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtld::CGroup::FS', tmpdir)
      force_cgroup(2, [''])
      path = %w[osctl pool.tank user.4220 ct.27687]
      FileUtils.mkdir_p(File.join(tmpdir, *path))
      delegated = []

      allow(described_class).to receive(:delegate_available_controllers) do |cgroup|
        delegated << File.expand_path(cgroup)
      end

      expect(described_class.mkpath('cpuset', [''] + path, leaf: false)).to be(false)
      expect(delegated).to eq(
        path.each_index.map { |i| File.join(tmpdir, *path[0..i]) }
      )
    end
  end

  it 'delegates only missing cgroup v2 controllers' do
    with_tmpdir do |tmpdir|
      cgroup = mkdir_cgroup(tmpdir, 'osctl')
      write_cgroup_file(cgroup, 'cgroup.controllers', content: "cpuset cpu memory\n")
      write_cgroup_file(cgroup, 'cgroup.subtree_control', content: "cpu\n")

      allow(File).to receive(:write).and_call_original

      described_class.delegate_available_controllers(cgroup)

      expect(File).to have_received(:write).with(
        File.join(cgroup, 'cgroup.subtree_control'),
        '+cpuset +memory'
      )
    end
  end

  it 'falls back to tasks when cgroup.procs is unavailable' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtld::CGroup::FS', tmpdir)
      force_cgroup(1, ['cpu,cpuacct'])
      FileUtils.mkdir_p(File.join(tmpdir, 'cpu,cpuacct'))

      cgroup = File.join(tmpdir, 'cpu,cpuacct', 'osctl', 'ct.ct1')
      FileUtils.mkdir_p(cgroup)
      tasks_file = instance_double(IO, puts: nil)
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open)
        .with(File.join(cgroup, 'cgroup.procs'), 'w')
        .and_raise(Errno::ENOENT)
      allow(File).to receive(:open)
        .with(File.join(cgroup, 'tasks'), 'w')
        .and_yield(tasks_file)

      described_class.attach_to('cpu', %w[osctl ct.ct1], pid: 4321)

      expect(File).to have_received(:open).with(File.join(cgroup, 'tasks'), 'w')
      expect(tasks_file).to have_received(:puts).with(4321)
    end
  end

  it 'parses named and unified process cgroups' do
    allow(described_class).to receive(:v1?).and_return(true)
    allow(File).to receive(:open)
      .with('/proc/123/cgroup')
      .and_yield(StringIO.new("9:cpu,cpuacct:/osctl/ct.ct1\n8:name=systemd:/user.slice\n0::/unified\n"))

    expect(described_class.get_process_cgroups(123)).to eq(
      'cpu,cpuacct' => '/osctl/ct.ct1',
      'systemd' => '/user.slice',
      'unified' => '/unified'
    )
  end

  it 'returns only positive integer pids from cgroup.procs' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtld::CGroup::FS', tmpdir)
      force_cgroup(1, ['memory'])
      FileUtils.mkdir_p(File.join(tmpdir, 'memory'))

      write_cgroup_file(tmpdir, 'memory', 'osctl', 'ct.ct1', 'cgroup.procs', content: "1\n0\n12\n-1\n")

      expect(described_class.get_cgroup_pids('memory', File.join('osctl', 'ct.ct1'))).to eq([1, 12])
    end
  end

  it 'enumerates process ids throughout a generation tree on cgroup v2' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtld::CGroup::FS', tmpdir)
      force_cgroup(2, [''])
      root = File.join(tmpdir, 'osctl', 'ct.ct1', 'runs', 'run1')
      child = File.join(root, 'user-owned', 'payload')
      FileUtils.mkdir_p(child)
      File.write(File.join(root, 'cgroup.procs'), "10\n")
      File.write(File.join(child, 'cgroup.procs'), "11\n10\n")

      expect(
        described_class.get_tree_pids('osctl/ct.ct1/runs/run1')
      ).to contain_exactly(10, 11)
    end
  end

  it 'uses the pids hierarchy for generation process ids on cgroup v1' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtld::CGroup::FS', tmpdir)
      force_cgroup(1, %w[memory pids])
      root = File.join(tmpdir, 'pids', 'osctl', 'ct.ct1', 'runs', 'run1')
      FileUtils.mkdir_p(root)
      File.write(File.join(root, 'cgroup.procs'), "42\n")

      expect(
        described_class.get_tree_pids('osctl/ct.ct1/runs/run1')
      ).to eq([42])
    end
  end

  it 'prevents forks in every descendant with a pids.max file' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtld::CGroup::FS', tmpdir)
      force_cgroup(2, [''])
      root = File.join(tmpdir, 'osctl', 'ct.ct1', 'runs', 'run1')
      child = File.join(root, 'user-owned')
      FileUtils.mkdir_p(child)
      [root, child].each { |dir| File.write(File.join(dir, 'pids.max'), 'max') }

      described_class.prevent_forks('osctl/ct.ct1/runs/run1')

      expect(File.read(File.join(root, 'pids.max'))).to eq('0')
      expect(File.read(File.join(child, 'pids.max'))).to eq('0')
    end
  end

  it 'is re-entrant when sync is called while holding the mutex' do
    calls = []

    described_class.sync do
      calls << :outer
      described_class.sync do
        calls << :inner
      end
    end

    expect(calls).to eq(%i[outer inner])
  end

  it 'serializes every cpuset parameter write with hierarchy transactions' do
    with_tmpdir do |tmpdir|
      path = File.join(tmpdir, 'cpuset.cpus')
      File.write(path, '0-3')
      mutex_owned = nil
      allow(File).to receive(:write).and_wrap_original do |method, *args|
        mutex_owned = described_class::MUTEX.owned? if args.first == path
        method.call(*args)
      end

      expect(described_class.set_param(path, ['2,3'])).to be(true)
      expect(mutex_owned).to be(true)
      expect(File.read(path)).to eq('2,3')
    end
  end
end
