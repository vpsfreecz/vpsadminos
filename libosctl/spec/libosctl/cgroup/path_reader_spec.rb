# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/cli/presentable'
require 'libosctl/cgroup'
require 'libosctl/meminfo'
require 'libosctl/os_process'
require 'libosctl/utils/humanize'
require 'libosctl/cgroup/path_reader'

RSpec.describe OsCtl::Lib::CGroup::PathReader do
  def raw_values(hash)
    hash.transform_values do |value|
      value.is_a?(OsCtl::Lib::Cli::Presentable) ? value.raw : value
    end
  end

  shared_examples 'cgroup path reader' do |version|
    let(:cg_path) { '/osctl/pool.tank/ct.ct1/user-owned' }

    { '50000' => 50.0, '150000' => 150.0, '200000' => 200.0, '1' => 0.001 }.each do |quota, percent|
      it "reads quota #{quota}/100000 as #{percent} percent of one CPU" do
        with_tmpdir do |dir|
          reader = build_reader(version, dir, cg_path)
          write_cpu_limit(version, dir, cg_path, quota:, period: '100000')
          limit = reader.read_stats([:cpu_limit], false).fetch(:cpu_limit)

          expect(limit).to be_a(OsCtl::Lib::Cli::Presentable)
          expect(limit.raw).to eq(percent)
        end
      end
    end

    [
      ['garbage', '100000'], ['50000x', '100000'], ['0', '100000'], ['-2', '100000'],
      ['50000', 'garbage'], ['50000', '0'], ['50000', '-100000']
    ].each do |quota, period|
      it "rejects invalid finite CPU quota/period #{quota}/#{period}" do
        with_tmpdir do |dir|
          reader = build_reader(version, dir, cg_path)
          write_cpu_limit(version, dir, cg_path, quota:, period:)

          expect { reader.read_stats([:cpu_limit], true) }.to raise_error(ArgumentError)
        end
      end
    end

    it 'retains the unlimited CPU sentinel' do
      with_tmpdir do |dir|
        reader = build_reader(version, dir, cg_path)
        write_cpu_limit(version, dir, cg_path, quota: version == :v1 ? '-1' : 'max', period: '100000')

        expect(reader.read_stats([:cpu_limit], true)).to eq({})
      end
    end

    it 'keeps a missing CPU limit unknown' do
      with_tmpdir do |dir|
        reader = build_reader(version, dir, cg_path)
        parent = File.dirname(cg_path.sub(%r{^/}, ''))
        relative = version == :v1 ? File.join('cpu', parent, 'cpu.cfs_quota_us') : File.join(parent, 'cpu.max')
        File.unlink(File.join(dir, relative))

        expect(reader.read_stats([:cpu_limit], true)).to eq(cpu_limit: nil)
      end
    end

    it 'reads common stats, params, and available parameters' do
      with_tmpdir do |dir|
        reader = build_reader(version, dir, cg_path)

        stats = raw_values(
          reader.read_stats(
            %i[memory memory_limit memory_pct cpu_us cpu_user_us cpu_system_us cpu_limit nproc],
            true
          )
        )

        expect(stats).to include(
          memory: 2048,
          memory_limit: 4096,
          memory_pct: 50.0,
          cpu_limit: 200,
          nproc: 42
        )

        if version == :v1
          expect(stats).to include(cpu_us: 3000, cpu_user_us: 2000, cpu_system_us: 1000)
          expect(raw_values(reader.read_params(['memory.limit_in_bytes', 'memory.missing']))).to eq(
            'memory.limit_in_bytes': 8192,
            'memory.missing': nil
          )
          expect(reader.list_available_params).to include(
            'cpuacct.stat',
            'cpuacct.usage',
            'memory.memsw.usage_in_bytes'
          )
        else
          expect(stats).to include(cpu_us: 3_000_000, cpu_user_us: 2_000_000, cpu_system_us: 1_000_000)
          expect(raw_values(reader.read_params(['memory.max', 'missing.param']))).to eq(
            'memory.max': 4096,
            'missing.param': nil
          )
          expect(reader.list_available_params).to include('cpu.stat', 'memory.current', 'pids.current')
        end
      end
    end
  end

  def write_cpu_limit(version, root, path, quota:, period:)
    parent = File.dirname(path.sub(%r{^/}, ''))
    if version == :v1
      write_sysfs_file(root, File.join('cpu', parent, 'cpu.cfs_quota_us'), "#{quota}\n")
      write_sysfs_file(root, File.join('cpu', parent, 'cpu.cfs_period_us'), "#{period}\n")
    else
      write_sysfs_file(root, File.join(parent, 'cpu.max'), "#{quota} #{period}\n")
    end
  end

  it_behaves_like 'cgroup path reader', :v1
  it_behaves_like 'cgroup path reader', :v2

  it 'returns unlimited limits on v2 and includes the combined cpu_hz value' do
    with_tmpdir do |dir|
      path = '/osctl/pool.tank/ct.ct2/user-owned'
      child = path.sub(%r{^/}, '')
      parent = File.dirname(child)

      write_sysfs_file(dir, File.join(child, 'memory.current'), "2048\n")
      write_sysfs_file(dir, File.join(child, 'cpu.stat'), <<~CPUSTAT)
        usage_usec 1500000
        user_usec 1000000
        system_usec 500000
      CPUSTAT
      write_sysfs_file(dir, File.join(child, 'pids.current'), "42\n")
      write_sysfs_file(dir, File.join(parent, 'memory.max'), "max\n")
      write_sysfs_file(dir, File.join(parent, 'cpu.max'), "max 100000\n")

      allow(OsCtl::Lib::CGroup).to receive_messages(v1?: false, fs: dir)

      reader = described_class.new({}, path)

      expect(raw_values(reader.read_stats(%i[memory_limit cpu_limit], true))).to eq({})

      expect(reader.read_stats(%i[cpu_hz cpu_user_hz cpu_system_hz], true)).to include(
        cpu_hz: 150,
        cpu_user_hz: 100,
        cpu_system_hz: 50
      )
    end
  end

  def build_reader(version, root, path)
    child = path.sub(%r{^/}, '')
    parent = File.dirname(child)

    case version
    when :v1
      subsystems = {
        memory: File.join(root, 'memory'),
        cpuacct: File.join(root, 'cpuacct'),
        cpu: File.join(root, 'cpu'),
        pids: File.join(root, 'pids')
      }

      write_sysfs_file(subsystems[:memory], File.join(child, 'memory.memsw.usage_in_bytes'), "2048\n")
      write_sysfs_file(subsystems[:memory], File.join(parent, 'memory.memsw.limit_in_bytes'), "4096\n")
      write_sysfs_file(subsystems[:memory], File.join(parent, 'memory.limit_in_bytes'), "8192\n")
      write_sysfs_file(subsystems[:cpuacct], File.join(child, 'cpuacct.usage'), "3000000\n")
      write_sysfs_file(subsystems[:cpuacct], File.join(child, 'cpuacct.usage_user'), "2000000\n")
      write_sysfs_file(subsystems[:cpuacct], File.join(child, 'cpuacct.usage_sys'), "1000000\n")
      write_sysfs_file(subsystems[:cpuacct], File.join(child, 'cpuacct.stat'), "user 2\nsystem 1\n")
      write_sysfs_file(subsystems[:cpu], File.join(parent, 'cpu.cfs_quota_us'), "200000\n")
      write_sysfs_file(subsystems[:cpu], File.join(parent, 'cpu.cfs_period_us'), "100000\n")
      write_sysfs_file(subsystems[:pids], File.join(child, 'pids.current'), "42\n")

      allow(OsCtl::Lib::CGroup).to receive(:v1?).and_return(true)

      described_class.new(subsystems, path)

    when :v2
      write_sysfs_file(root, File.join(child, 'memory.current'), "2048\n")
      write_sysfs_file(root, File.join(parent, 'memory.max'), "4096\n")
      write_sysfs_file(root, File.join(child, 'cpu.stat'), <<~CPUSTAT)
        usage_usec 3000000
        user_usec 2000000
        system_usec 1000000
      CPUSTAT
      write_sysfs_file(root, File.join(parent, 'cpu.max'), "200000 100000\n")
      write_sysfs_file(root, File.join(child, 'pids.current'), "42\n")

      allow(OsCtl::Lib::CGroup).to receive_messages(v1?: false, fs: root)

      described_class.new({}, path)
    end
  end
end
