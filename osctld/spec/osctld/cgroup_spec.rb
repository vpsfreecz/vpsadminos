# frozen_string_literal: true

require 'stringio'
require 'osctld/exceptions'
require 'osctld/run_state'
require 'osctld/cgroup'

RSpec.describe OsCtld::CGroup do
  around do |example|
    fs = described_class.instance_variable_get(:@fs)
    version = described_class.instance_variable_get(:@version)
    subsystems = described_class.instance_variable_get(:@subsystems)
    described_class.instance_variable_set(:@fs, nil)
    described_class.instance_variable_set(:@version, nil)
    described_class.instance_variable_set(:@subsystems, nil)
    example.run
  ensure
    described_class.instance_variable_set(:@fs, fs)
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

  def stub_cgroup_filesystems(default_fs:, runstate_fs: File.join(default_fs, 'runstate-missing'))
    stub_const("#{described_class}::RUNSTATE_FS", runstate_fs)
    stub_const("#{described_class}::DEFAULT_FS", default_fs)
  end

  def force_cgroup(version, subsystems, fs:)
    described_class.instance_variable_set(:@fs, fs)
    described_class.instance_variable_set(:@version, version)
    described_class.instance_variable_set(:@subsystems, subsystems)
  end

  def reset_cgroup(version:)
    described_class.instance_variable_set(:@fs, nil)
    described_class.instance_variable_set(:@version, version)
    described_class.instance_variable_set(:@subsystems, nil)
  end

  it 'defaults to cgroup v1 when the version file is missing' do
    with_tmpdir do |tmpdir|
      FileUtils.mkdir_p(File.join(tmpdir, 'cpu'))
      stub_cgroup_filesystems(default_fs: tmpdir)
      stub_missing_cgroup_version

      described_class.init

      expect(described_class.version).to eq(1)
      expect(described_class.subsystems).to eq(['cpu'])
    end
  end

  it 'does not expose a stale fixed cgroupfs alias' do
    expect(described_class.const_defined?(:FS, false)).to be(false)
  end

  it 'clamps invalid cgroup versions to v1' do
    with_tmpdir do |tmpdir|
      FileUtils.mkdir_p(File.join(tmpdir, 'cpu'))
      stub_cgroup_filesystems(default_fs: tmpdir)
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
      stub_cgroup_filesystems(default_fs: tmpdir)

      FileUtils.mkdir_p(File.join(tmpdir, 'cpu,cpuacct'))
      FileUtils.touch(File.join(tmpdir, 'cgroup.procs'))
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

  it 'prefers the runstate cgroupfs bind mount on cgroup v2' do
    Dir.mktmpdir do |dir|
      runstate_fs = File.join(dir, 'runstate')
      default_fs = File.join(dir, 'default')

      FileUtils.mkdir_p(runstate_fs)
      FileUtils.mkdir_p(default_fs)
      FileUtils.touch(File.join(runstate_fs, 'cgroup.procs'))
      FileUtils.touch(File.join(default_fs, 'cgroup.procs'))

      stub_const("#{described_class}::RUNSTATE_FS", runstate_fs)
      stub_const("#{described_class}::DEFAULT_FS", default_fs)
      reset_cgroup(version: 2)

      expect(described_class.fs).to eq(runstate_fs)
      expect(described_class.abs_cgroup_path(nil, 'osctl')).to eq(
        File.join(runstate_fs, 'osctl')
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
      force_cgroup(1, ['cpu,cpuacct'], fs: tmpdir)
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
      force_cgroup(2, [''], fs: tmpdir)
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
      force_cgroup(2, [''], fs: tmpdir)
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
      force_cgroup(1, ['cpu,cpuacct'], fs: tmpdir)
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
      force_cgroup(1, ['memory'], fs: tmpdir)
      FileUtils.mkdir_p(File.join(tmpdir, 'memory'))

      write_cgroup_file(tmpdir, 'memory', 'osctl', 'ct.ct1', 'cgroup.procs', content: "1\n0\n12\n-1\n")

      expect(described_class.get_cgroup_pids('memory', File.join('osctl', 'ct.ct1'))).to eq([1, 12])
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

  it 'falls back to the default cgroupfs path when runstate is unavailable' do
    Dir.mktmpdir do |dir|
      runstate_fs = File.join(dir, 'missing')
      default_fs = File.join(dir, 'default')

      FileUtils.mkdir_p(default_fs)
      FileUtils.touch(File.join(default_fs, 'cgroup.procs'))

      stub_const("#{described_class}::RUNSTATE_FS", runstate_fs)
      stub_const("#{described_class}::DEFAULT_FS", default_fs)
      reset_cgroup(version: 2)

      expect(described_class.fs).to eq(default_fs)
    end
  end
end
