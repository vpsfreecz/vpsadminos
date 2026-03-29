# frozen_string_literal: true

require 'osctld/lockable'
require 'osctld/container/run_id'
require 'osctld/garbage_collector'

RSpec.describe OsCtld::GarbageCollector do
  def stub_gc_daemon(prune_interval: 0.01)
    gc_cfg = Struct.new(:prune_interval).new(prune_interval)
    daemon_cfg = Struct.new(:garbage_collector).new(gc_cfg)
    daemon = Struct.new(:config).new(daemon_cfg)

    stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
  end

  def build_pool(tmpdir)
    Struct.new(:name, :conf_path, keyword_init: true).new(
      name: 'tank',
      conf_path: File.join(tmpdir, 'conf')
    )
  end

  it 'round-trips container run datasets through dump and load' do
    run_id = OsCtld::Container::RunId.new(pool_name: 'tank', container_id: 'ct1', timestamp: 1.5)
    dataset = OsCtl::Lib::Zfs::Dataset.new('tank/ct1-run')
    original = described_class::ContainerRunDataset.new(run_id, dataset)
    restored = described_class::ContainerRunDataset.load(original.dump)

    expect(restored.dump).to eq(original.dump)
    expect(restored).to eq(original)
  end

  it 'reports started? from the worker lifecycle' do
    with_tmpdir do |tmpdir|
      stub_gc_daemon
      pool = build_pool(tmpdir)
      FileUtils.mkdir_p(File.join(pool.conf_path, 'pool'))
      gc = described_class.new(pool)

      expect(gc.started?).to be(false)

      gc.start
      expect(gc.started?).to be(true)

      gc.stop
      expect(gc.started?).to be(false)
    end
  end

  it 'exports the garbage collector configuration file as an asset' do
    with_tmpdir do |tmpdir|
      pool = build_pool(tmpdir)
      FileUtils.mkdir_p(File.join(pool.conf_path, 'pool'))
      gc = described_class.new(pool)
      add = Class.new do
        def file(*, **); end
      end.new
      allow(add).to receive(:file)

      gc.assets(add)

      expect(add).to have_received(:file).with(
        File.join(pool.conf_path, 'pool', 'garbage-collector.yml'),
        desc: 'Configuration file for garbage collector',
        optional: true
      )
    end
  end

  it 'loads existing serialized entries and tolerates a missing config file' do
    with_tmpdir do |tmpdir|
      pool = build_pool(tmpdir)
      config_dir = File.join(pool.conf_path, 'pool')
      FileUtils.mkdir_p(config_dir)
      run_id = OsCtld::Container::RunId.new(pool_name: 'tank', container_id: 'ct1', timestamp: 2.5)
      cfg = {
        'container_run_datasets' => [
          described_class::ContainerRunDataset.new(
            run_id,
            OsCtl::Lib::Zfs::Dataset.new('tank/ct1-run')
          ).dump
        ]
      }
      File.write(
        File.join(config_dir, 'garbage-collector.yml'),
        OsCtl::Lib::ConfigFile.dump_yaml(cfg)
      )

      loaded = described_class.new(pool)

      expect(loaded.instance_variable_get(:@container_run_datasets)).to eq([
                                                                             described_class::ContainerRunDataset.new(
                                                                               run_id,
                                                                               OsCtl::Lib::Zfs::Dataset.new('tank/ct1-run')
                                                                             )
                                                                           ])

      FileUtils.rm_f(File.join(config_dir, 'garbage-collector.yml'))

      expect { described_class.new(pool) }.not_to raise_error
    end
  end

  it 'persists added container run datasets' do
    with_tmpdir do |tmpdir|
      pool = build_pool(tmpdir)
      FileUtils.mkdir_p(File.join(pool.conf_path, 'pool'))
      gc = described_class.new(pool)
      run_id = OsCtld::Container::RunId.new(pool_name: 'tank', container_id: 'ct1', timestamp: 3.5)
      run_conf = Struct.new(:run_id).new(run_id)
      dataset = OsCtl::Lib::Zfs::Dataset.new('tank/ct1-run')

      gc.add_container_run_dataset(run_conf, dataset)

      cfg = OsCtl::Lib::ConfigFile.load_yaml_file(
        File.join(pool.conf_path, 'pool', 'garbage-collector.yml')
      )

      expect(cfg['container_run_datasets']).to eq([
                                                    {
                                                      'run_id' => run_id.dump,
                                                      'dataset' => 'tank/ct1-run'
                                                    }
                                                  ])
    end
  end
end
