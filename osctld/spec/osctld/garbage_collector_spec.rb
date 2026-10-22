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
    Struct.new(:name, :conf_path, :trash_bin, keyword_init: true).new(
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

  describe 'import ownership snapshots' do
    it 'permits explicit absence only with empty ownership, keeping the default strict' do
      with_tmpdir do |root|
        pool = build_pool(root)
        FileUtils.mkdir_p(File.join(pool.conf_path, 'pool'))
        gc = described_class.new(pool)
        expect { gc.container_run_dataset_ownership }.to raise_error(Errno::ENOENT)
        expect(gc.container_run_dataset_ownership(allow_missing: true)).to eq([[], nil])
        path = File.join(pool.conf_path, 'pool', 'garbage-collector.yml')
        expect(File.exist?(path)).to be(false)
        run = Struct.new(:run_id).new(OsCtld::Container::RunId.new(pool_name: 'tank', container_id: 'ct1', timestamp: 1.5))
        gc.add_container_run_dataset(run, OsCtl::Lib::Zfs::Dataset.new('tank/ct1-run'))
        File.unlink(path)
        expect { gc.container_run_dataset_ownership(allow_missing: true) }.to raise_error(Errno::ENOENT)
      end
    end

    %i[malformed symlink unreadable].each do |kind|
      it "does not treat #{kind} ownership evidence as absence" do
        with_tmpdir do |root|
          pool = build_pool(root)
          FileUtils.mkdir_p(File.join(pool.conf_path, 'pool'))
          gc = described_class.new(pool)
          path = File.join(pool.conf_path, 'pool', 'garbage-collector.yml')
          case kind
          when :malformed then File.write(path, "---\n[\n")
          when :symlink then File.symlink(File.join(root, 'missing'), path)
          when :unreadable
            allow(File).to receive(:open).and_call_original
            allow(File).to receive(:open).with(path, File::RDONLY | File::NOFOLLOW).and_raise(Errno::EACCES)
          end
          error = kind == :malformed ? Psych::SyntaxError : SystemCallError
          expect { gc.container_run_dataset_ownership(allow_missing: true) }.to raise_error(error)
        end
      end
    end
  end

  describe 'inhibited retirement' do
    def build_collector(tmpdir)
      OsCtl::Lib::Logger.setup(:none)
      stub_gc_daemon(prune_interval: 60)
      pool = build_pool(tmpdir)
      pool.trash_bin = Class.new do
        def add_dataset(_dataset); end
      end.new
      allow(pool.trash_bin).to receive(:add_dataset)
      FileUtils.mkdir_p(File.join(pool.conf_path, 'pool'))
      stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      [pool, described_class.new(pool)]
    end

    def register_dataset(gc, id: 'ct1', dataset: 'tank/ct1-run')
      run_id = OsCtld::Container::RunId.new(pool_name: 'tank', container_id: id, timestamp: 1.5)
      rc = Struct.new(:run_id).new(run_id)
      ds = OsCtl::Lib::Zfs::Dataset.new(dataset)
      gc.add_container_run_dataset(rc, ds)
      [rc, ds]
    end

    def config_bytes(pool)
      File.binread(File.join(pool.conf_path, 'pool', 'garbage-collector.yml'))
    end

    # Observe the actual destructive sink, then join the worker only after all
    # requested sink calls have returned. Stopping before this point could skip
    # pruning entirely and make a broken test appear to protect the datasets.
    def run_until_retirement_attempts(gc, count: 1)
      attempted = OsCtl::Lib::Queue.new
      allow(gc).to receive(:trash_dataset).and_wrap_original do |original, dataset|
        result = original.call(dataset)
        attempted << [dataset.name, result]
        result
      end

      gc.start
      yield
      Array.new(count) do
        attempted.pop(timeout: 1) || raise('GC did not consume the retirement request')
      end
    ensure
      gc.stop
    end

    it 'retains every duplicate owner when a queued prune is inhibited' do
      with_tmpdir do |tmpdir|
        pool, gc = build_collector(tmpdir)
        register_dataset(gc)
        register_dataset(gc, id: 'foreign-ct')
        before = config_bytes(pool)
        gc.inhibit_retirement

        attempts = run_until_retirement_attempts(gc, count: 2) { gc.prune }

        expect(attempts).to eq([['tank/ct1-run', false], ['tank/ct1-run', false]])
        expect(pool.trash_bin).not_to have_received(:add_dataset)
        expect(config_bytes(pool)).to eq(before)
        expect(gc.started?).to be(false)
      end
    end

    it 'also retains ownership when the periodic prune deadline expires' do
      with_tmpdir do |tmpdir|
        pool, gc = build_collector(tmpdir)
        register_dataset(gc)
        before = config_bytes(pool)
        gc.inhibit_retirement
        stub_gc_daemon(prune_interval: 0.01)

        attempts = run_until_retirement_attempts(gc) { nil }

        expect(attempts).to eq([['tank/ct1-run', false]])
        expect(pool.trash_bin).not_to have_received(:add_dataset)
        expect(config_bytes(pool)).to eq(before)
      end
    end

    it 'consumes queued registered and unregistered frees without losing ownership or inventing records' do
      with_tmpdir do |tmpdir|
        pool, gc = build_collector(tmpdir)
        rc, dataset = register_dataset(gc)
        register_dataset(gc, id: 'foreign-ct')
        legacy_dataset = OsCtl::Lib::Zfs::Dataset.new('tank/legacy-unregistered')
        before = config_bytes(pool)
        gc.inhibit_retirement

        attempts = run_until_retirement_attempts(gc, count: 2) do
          gc.free_container_run_dataset(rc, dataset)
          gc.free_container_run_dataset(rc, legacy_dataset)
        end

        expect(attempts).to eq([['tank/ct1-run', false], ['tank/legacy-unregistered', false]])
        expect(pool.trash_bin).not_to have_received(:add_dataset)
        expect(config_bytes(pool)).to eq(before)
        expect(gc.started?).to be(false)
      end
    end

    it 'keeps inhibition monotonic across concurrent callers and ordinary registrations' do
      with_tmpdir do |tmpdir|
        pool, gc = build_collector(tmpdir)
        Thread.new { gc.inhibit_retirement }.value
        callers = Array.new(4) { Thread.new { gc.inhibit_retirement } }
        rc, dataset = register_dataset(gc)
        callers.each(&:value)
        before = config_bytes(pool)

        attempts = run_until_retirement_attempts(gc) { gc.free_container_run_dataset(rc, dataset) }

        expect(attempts).to eq([['tank/ct1-run', false]])
        expect(pool.trash_bin).not_to have_received(:add_dataset)
        expect(config_bytes(pool)).to eq(before)
        expect(gc.started?).to be(false)
      end
    end

    it 'keeps inhibition for a restarted worker but not for a fresh collector' do
      with_tmpdir do |tmpdir|
        pool, gc = build_collector(tmpdir)
        rc, dataset = register_dataset(gc)
        gc.inhibit_retirement
        before = config_bytes(pool)

        2.times do
          expect(run_until_retirement_attempts(gc) { gc.prune }).to eq([['tank/ct1-run', false]])
        end
        expect(config_bytes(pool)).to eq(before)
        fresh = described_class.new(pool)

        attempts = run_until_retirement_attempts(fresh) { fresh.free_container_run_dataset(rc, dataset) }

        expect(attempts).to eq([['tank/ct1-run', true]])
        expect(pool.trash_bin).to have_received(:add_dataset).with(dataset).once
        expect(OsCtl::Lib::ConfigFile.load_yaml(config_bytes(pool))).to eq('container_run_datasets' => [])
      end
    end

    it 'still retires unused registered datasets through an uninhibited queued prune' do
      with_tmpdir do |tmpdir|
        pool, gc = build_collector(tmpdir)
        register_dataset(gc)

        attempts = run_until_retirement_attempts(gc) { gc.prune }

        expect(attempts).to eq([['tank/ct1-run', true]])
        expect(pool.trash_bin).to have_received(:add_dataset).with(have_attributes(name: 'tank/ct1-run')).once
        expect(OsCtl::Lib::ConfigFile.load_yaml(config_bytes(pool))).to eq('container_run_datasets' => [])
      end
    end

    it 'still consumes an uninhibited legacy free that has no registered record' do
      with_tmpdir do |tmpdir|
        pool, gc = build_collector(tmpdir)
        run_id = OsCtld::Container::RunId.new(pool_name: 'tank', container_id: 'ct1', timestamp: 2.5)
        rc = Struct.new(:run_id).new(run_id)
        dataset = OsCtl::Lib::Zfs::Dataset.new('tank/legacy-unregistered')

        attempts = run_until_retirement_attempts(gc) { gc.free_container_run_dataset(rc, dataset) }

        expect(attempts).to eq([['tank/legacy-unregistered', true]])
        expect(pool.trash_bin).to have_received(:add_dataset).with(dataset).once
        expect(OsCtl::Lib::ConfigFile.load_yaml(config_bytes(pool))).to eq('container_run_datasets' => [])
      end
    end
  end
end
