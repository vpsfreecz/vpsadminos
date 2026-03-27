# frozen_string_literal: true

require 'osctld/lockable'
require 'osctld/container/hints'

HintsSpecContainer = Struct.new(:base_cgroup_path, keyword_init: true)

class HintsSpecPathReader
  def read_stats(*); end
end

RSpec.describe OsCtld::Container::Hints do
  describe OsCtld::Container::Hints::CpuDaily do
    it 'loads and dumps cpu usage values' do
      daily = described_class.load(
        'user_us' => 1_000,
        'system_us' => 500
      )

      expect(daily.user_us).to eq(1_000)
      expect(daily.system_us).to eq(500)
      expect(daily.dump).to eq(
        'user_us' => 1_000,
        'system_us' => 500
      )
    end

    it 'normalizes usage to a 24-hour window' do
      daily = described_class.new(user_us: 0, system_us: 0)

      daily.update(86_400, 43_200, 86_400)

      expect(daily.user_us).to eq(86_400)
      expect(daily.system_us).to eq(43_200)
      expect(daily.usage_us).to eq(129_600)
    end

    it 'averages repeated updates' do
      daily = described_class.new(user_us: 0, system_us: 0)

      daily.update(86_400, 43_200, 86_400)
      daily.update(172_800, 86_400, 86_400)

      expect(daily.user_us).to eq(129_600)
      expect(daily.system_us).to eq(64_800)
      expect(daily.usage_us).to eq(194_400)
    end
  end

  describe '.load' do
    it 'builds hints with cpu_daily defaults from config' do
      ct = instance_double(HintsSpecContainer)
      hints = described_class.load(ct, 'cpu_daily' => { 'user_us' => 1_000, 'system_us' => 500 })

      expect(hints.ct).to eq(ct)
      expect(hints.cpu_daily.user_us).to eq(1_000)
      expect(hints.cpu_daily.system_us).to eq(500)
      expect(hints.dump).to eq(
        'cpu_daily' => {
          'user_us' => 1_000,
          'system_us' => 500
        }
      )
    end
  end

  describe '#dup' do
    it 'rebinds the container and duplicates the cpu daily tracker' do
      ct = instance_double(HintsSpecContainer)
      replacement = instance_double(HintsSpecContainer)
      hints = described_class.load(ct, 'cpu_daily' => { 'user_us' => 1_000, 'system_us' => 500 })

      copy = hints.dup(replacement)
      copy.cpu_daily.update(172_800, 86_400, 86_400)

      expect(copy.ct).to eq(replacement)
      expect(copy.cpu_daily.user_us).to eq(86_900)
      expect(copy.cpu_daily.system_us).to eq(43_450)
      expect(hints.cpu_daily.user_us).to eq(1_000)
      expect(hints.cpu_daily.system_us).to eq(500)
    end
  end

  describe '#account_cpu_use' do
    let(:now) { Time.at(2_000_000) }
    let(:ct) do
      instance_double(HintsSpecContainer, base_cgroup_path: '/osctl/pool.tank/user.alice/ct.ct1')
    end
    let(:reader) { instance_double(HintsSpecPathReader) }
    let(:value) { Struct.new(:raw) }

    before do
      stub_const('OsCtld::CGroup', Module.new do
        def self.subsystem_paths
          { 'cpuacct' => '/sys/fs/cgroup/cpuacct' }
        end

        def self.abs_cgroup_path(_subsystem, path)
          File.join('/sys/fs/cgroup/cpuacct', path)
        end
      end)

      allow(OsCtl::Lib::CGroup::PathReader).to receive(:new).and_return(reader)
      allow(Time).to receive(:now).and_return(now)
    end

    it 'accounts cpu use when stats and cgroup mtime are available' do
      allow(reader).to receive(:read_stats).and_return(
        cpu_us: value.new(129_600),
        cpu_user_us: value.new(86_400),
        cpu_system_us: value.new(43_200)
      )
      allow(File).to receive(:stat).and_return(instance_double(File::Stat, mtime: now - 86_400))

      hints = described_class.new(ct)
      hints.account_cpu_use

      expect(hints.cpu_daily.user_us).to eq(86_400)
      expect(hints.cpu_daily.system_us).to eq(43_200)
      expect(hints.cpu_daily.usage_us).to eq(129_600)
    end

    it 'returns early when stats are incomplete' do
      allow(reader).to receive(:read_stats).and_return(
        cpu_us: nil,
        cpu_user_us: value.new(86_400),
        cpu_system_us: value.new(43_200)
      )
      allow(File).to receive(:stat)

      hints = described_class.new(ct)
      hints.account_cpu_use

      expect(File).not_to have_received(:stat)
      expect(hints.cpu_daily.usage_us).to eq(0)
    end

    it 'returns early when cgroup stat lookup fails' do
      allow(reader).to receive(:read_stats).and_return(
        cpu_us: value.new(129_600),
        cpu_user_us: value.new(86_400),
        cpu_system_us: value.new(43_200)
      )
      allow(File).to receive(:stat).and_raise(Errno::ENOENT)

      hints = described_class.new(ct)
      hints.account_cpu_use

      expect(hints.cpu_daily.usage_us).to eq(0)
    end
  end
end
