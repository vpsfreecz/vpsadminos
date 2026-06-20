# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/cgroup'

RSpec.describe OsCtl::Lib::CGroup do
  around do |example|
    reset_module_ivars(described_class, :@configuration)
    example.run
    reset_module_ivars(described_class, :@configuration)
  end

  def configure_paths(dir)
    runstate_fs = File.join(dir, 'runstate')
    default_fs = File.join(dir, 'default')
    version_file = File.join(dir, 'cgroup.version')

    stub_const('OsCtl::Lib::CGroup::RUNSTATE_FS', runstate_fs)
    stub_const('OsCtl::Lib::CGroup::DEFAULT_FS', default_fs)
    stub_const('OsCtl::Lib::CGroup::RUNSTATE_VERSION', version_file)

    [runstate_fs, default_fs, version_file]
  end

  def make_v1(path)
    FileUtils.mkdir_p(File.join(path, 'memory'))
  end

  def make_v2(path)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'cgroup.procs'), '')
  end

  it 'detects cgroup v2 from the default hierarchy' do
    with_tmpdir do |dir|
      _, default_fs, = configure_paths(dir)
      make_v2(default_fs)

      expect(described_class.fs).to eq(default_fs)
      expect(described_class.version).to eq(2)
      expect(described_class).to be_v2
      expect(described_class).not_to be_v1
    end
  end

  it 'detects cgroup v1 from the default hierarchy' do
    with_tmpdir do |dir|
      _, default_fs, = configure_paths(dir)
      make_v1(default_fs)

      expect(described_class.fs).to eq(default_fs)
      expect(described_class.version).to eq(1)
      expect(described_class).to be_v1
      expect(described_class).not_to be_v2
    end
  end

  it 'prefers a compatible runstate hierarchy selected by its version file' do
    with_tmpdir do |dir|
      runstate_fs, default_fs, version_file = configure_paths(dir)
      make_v2(runstate_fs)
      make_v1(default_fs)
      File.write(version_file, "2\n")

      expect(described_class.version).to eq(2)
      expect(described_class.fs).to eq(runstate_fs)
    end
  end

  it 'publishes the same runstate pair when fs is read before version' do
    with_tmpdir do |dir|
      runstate_fs, default_fs, version_file = configure_paths(dir)
      make_v2(runstate_fs)
      make_v1(default_fs)
      File.write(version_file, "2\n")

      expect(described_class.fs).to eq(runstate_fs)
      expect(described_class.version).to eq(2)
    end
  end

  it 'publishes the same runstate pair when version is read before fs' do
    with_tmpdir do |dir|
      runstate_fs, default_fs, version_file = configure_paths(dir)
      make_v1(runstate_fs)
      make_v2(default_fs)
      File.write(version_file, "1\n")

      expect(described_class.version).to eq(1)
      expect(described_class.fs).to eq(runstate_fs)
    end
  end

  it 'falls back when the runstate hierarchy does not match its version' do
    with_tmpdir do |dir|
      runstate_fs, default_fs, version_file = configure_paths(dir)
      make_v1(runstate_fs)
      make_v2(default_fs)
      File.write(version_file, "2\n")

      expect(described_class.version).to eq(2)
      expect(described_class.fs).to eq(default_fs)
    end
  end

  it 'derives a consistent default pair when no hierarchy matches runstate' do
    with_tmpdir do |dir|
      runstate_fs, default_fs, version_file = configure_paths(dir)
      make_v1(runstate_fs)
      make_v1(default_fs)
      File.write(version_file, "2\n")

      expect(described_class.fs).to eq(default_fs)
      expect(described_class.version).to eq(1)
    end
  end

  it 'caches detection until both caches are reset' do
    with_tmpdir do |dir|
      runstate_fs, default_fs, version_file = configure_paths(dir)
      make_v2(default_fs)

      expect(described_class.version).to eq(2)
      expect(described_class.fs).to eq(default_fs)

      make_v1(runstate_fs)
      File.write(version_file, "1\n")

      expect(described_class.version).to eq(2)
      expect(described_class.fs).to eq(default_fs)

      reset_module_ivars(described_class, :@configuration)

      expect(described_class.version).to eq(1)
      expect(described_class.fs).to eq(runstate_fs)
    end
  end

  it 'initializes the version and path once across concurrent access' do
    with_tmpdir do |dir|
      runstate_fs, = configure_paths(dir)
      calls = 0
      call_mutex = Mutex.new
      allow(described_class).to receive(:detect_configuration) do
        call_mutex.synchronize { calls += 1 }
        sleep(0.01)
        [2, runstate_fs]
      end

      readers = 20.times.map do |i|
        Thread.new { i.even? ? described_class.version : described_class.fs }
      end

      expect(readers.map(&:value)).to eq(
        20.times.map { |i| i.even? ? 2 : runstate_fs }
      )
      expect(calls).to eq(1)
      expect(described_class.configuration).to eq([2, runstate_fs])
    end
  end
end
