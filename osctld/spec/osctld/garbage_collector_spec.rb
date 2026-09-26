# frozen_string_literal: true

require 'osctld/lockable'
require 'osctld/container/run_id'
require 'osctld/garbage_collector'
require 'osctld/trash_bin'
require 'osctld/storage_activity'
require 'timeout'

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

  def build_pool(tmpdir, activity: nil)
    Struct.new(
      :name, :conf_path, :storage_activity, :storage_activity_instance_uuid,
      :garbage_collector, :trash_bin, keyword_init: true
    ).new(
      name: 'tank',
      conf_path: File.join(tmpdir, 'conf'),
      storage_activity: activity,
      storage_activity_instance_uuid: activity&.attach_pool('tank'),
      trash_bin: instance_double(OsCtld::TrashBin, started?: true)
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

  it 'tracks registration and preserves queued work through pop and execution' do
    with_tmpdir do |tmpdir|
      stub_gc_daemon(prune_interval: 60)
      allow(OsCtl::Lib::Logger).to receive(:log)
      tracker = OsCtld::StorageActivity.new
      pool = build_pool(tmpdir, activity: tracker)
      FileUtils.mkdir_p(File.join(pool.conf_path, 'pool'))
      gc = described_class.new(pool)
      pool.garbage_collector = gc
      run_id = OsCtld::Container::RunId.new(pool_name: 'tank', container_id: 'ct1', timestamp: 3.5)
      gc.add_container_run_dataset(
        Struct.new(:run_id).new(run_id),
        OsCtl::Lib::Zfs::Dataset.new('tank/ct1-run')
      )

      expect(tracker.snapshot('tank', pool:)[:registered_run_datasets]).to eq(1)

      entered = Queue.new
      release = Queue.new
      allow(gc).to receive(:prune_container_run_datasets) do
        entered << true
        release.pop
      end

      gc.prune
      pending = tracker.snapshot('tank', pool:)
      expect(pending[:counts][:run_gc]).to eq(pending: 1, running: 0)

      gc.start
      Timeout.timeout(2) { entered.pop }
      running = tracker.snapshot('tank', pool:)
      expect(running[:counts][:run_gc]).to eq(pending: 0, running: 1)
    ensure
      release << true if release
      gc&.stop
      expect(tracker.snapshot('tank', pool:)[:counts][:run_gc]).to eq(pending: 0, running: 0)
    end
  end

  it 'keeps an unexpected worker death unknown' do
    with_tmpdir do |tmpdir|
      stub_gc_daemon(prune_interval: 60)
      tracker = OsCtld::StorageActivity.new
      pool = build_pool(tmpdir, activity: tracker)
      gc = described_class.new(pool)
      pool.garbage_collector = gc
      tracker.state('tank', pool.storage_activity_instance_uuid, 'active')

      gc.start
      thread = gc.instance_variable_get(:@thread)
      Timeout.timeout(2) { Thread.pass until thread.status == 'sleep' }
      thread.kill
      thread.join

      sample = tracker.snapshot('tank', pool:)
      expect(sample[:unknown_reasons]).to include('gc_worker_lost')
      expect(sample[:idle]).to be(false)
    end
  end
end
