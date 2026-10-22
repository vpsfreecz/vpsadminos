# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/promise'
require 'osctld/process_identity'
require 'osctld/container/run_id'
require 'osctld/container/run_configuration'
require 'osctld/garbage_collector'
require 'osctld/pool'

RSpec.describe OsCtld::Container::RunConfiguration do
  it 'assigns exit cleanup to one handler when callbacks race' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      results = Array.new(4) { Thread.new { rc.claim_exit_handling } }.map(&:value)

      expect(results.count(true)).to eq(1)
      expect(results.count(false)).to eq(3)
    end
  end

  def build_run_configuration(root:, **opts)
    ct = build_run_config_container(root:, **opts)
    [ct, described_class.new(ct, load_conf: false)]
  end

  it 'initializes from container defaults when no runtime config exists' do
    with_tmpdir do |dir|
      ct, rc = build_run_configuration(root: dir)

      expect(rc.dataset).to eq(ct.dataset)
      expect(rc.distribution).to eq(ct.distribution)
      expect(rc.version).to eq(ct.version)
      expect(rc.arch).to eq(ct.arch)
      expect(rc.vendor).to eq(ct.vendor)
      expect(rc.variant).to eq(ct.variant)
      expect(rc.destroy_dataset_on_stop?).to be(false)
      expect(rc.run_id.to_s).to include('tank:ct1:')
    end
  end

  it 'returns nil from .load when the runtime config file is missing' do
    with_tmpdir do |dir|
      ct = build_run_config_container(root: dir)

      expect(described_class.load(ct)).to be_nil
    end
  end

  it 'updates boot parameters through boot_from' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      boot_dataset = FakeObjects::FakeDataset.new(
        name: 'tank/imports/ct1',
        mountpoint: File.join(dir, 'datasets', 'boot')
      )
      FileUtils.mkdir_p(boot_dataset.mountpoint)

      rc.boot_from(
        dataset: boot_dataset,
        distribution: 'nixos',
        version: '24.11',
        arch: 'x86_64',
        vendor: 'custom',
        variant: 'minimal',
        destroy_dataset_on_stop: true
      )

      expect(rc.dataset).to eq(boot_dataset)
      expect(rc.distribution).to eq('nixos')
      expect(rc.version).to eq('24.11')
      expect(rc.arch).to eq('x86_64')
      expect(rc.vendor).to eq('custom')
      expect(rc.variant).to eq('minimal')
      expect(rc.destroy_dataset_on_stop?).to be(true)
    end
  end

  it 'persists distribution updates through set_distribution' do
    with_tmpdir do |dir|
      ct, rc = build_run_configuration(root: dir)

      rc.set_distribution(
        distribution: 'nixos',
        version: '24.11',
        arch: 'aarch64',
        vendor: 'custom',
        variant: 'minimal'
      )

      loaded = described_class.load(ct)

      expect(loaded.distribution).to eq('nixos')
      expect(loaded.version).to eq('24.11')
      expect(loaded.arch).to eq('aarch64')
      expect(loaded.vendor).to eq('custom')
      expect(loaded.variant).to eq('minimal')
    end
  end

  it 'round-trips saved runtime configuration' do
    with_tmpdir do |dir|
      ct, rc = build_run_configuration(root: dir)
      boot_dataset = FakeObjects::FakeDataset.new(
        name: 'tank/imports/ct1',
        mountpoint: File.join(dir, 'datasets', 'boot')
      )
      FileUtils.mkdir_p(boot_dataset.mountpoint)

      rc.boot_from(
        dataset: boot_dataset,
        distribution: 'nixos',
        version: '24.11',
        arch: 'x86_64',
        vendor: 'custom',
        variant: 'minimal',
        destroy_dataset_on_stop: true
      )
      rc.cpu_package = 2
      rc.save

      loaded = described_class.load(ct)

      expect(loaded.dump).to include(
        'dataset' => 'tank/imports/ct1',
        'distribution' => 'nixos',
        'version' => '24.11',
        'arch' => 'x86_64',
        'vendor' => 'custom',
        'variant' => 'minimal',
        'cpu_package' => 2,
        'destroy_dataset_on_stop' => true
      )
      expect(loaded.dataset.name).to eq('tank/imports/ct1')
      expect(loaded.destroy_dataset_on_stop?).to be(true)
    end
  end

  it 'mounts the boot dataset when it differs from the base dataset' do
    with_tmpdir do |dir|
      ct, rc = build_run_configuration(root: dir)
      boot_dataset = FakeObjects::FakeDataset.new(
        name: 'tank/imports/ct1',
        mountpoint: File.join(dir, 'datasets', 'boot')
      )
      FileUtils.mkdir_p(boot_dataset.mountpoint)

      rc.boot_from(
        dataset: boot_dataset,
        distribution: ct.distribution,
        version: ct.version,
        arch: ct.arch,
        vendor: ct.vendor,
        variant: ct.variant
      )

      allow(ct).to receive(:mount).and_call_original

      rc.mount

      expect(ct).to have_received(:mount).with(force: false)
      expect(boot_dataset.mount_calls).to eq([true])
      expect(rc.mounted?(force: false)).to be(true)
    end
  end

  it 'forwards force mounts to the container dataset mount' do
    with_tmpdir do |dir|
      ct, rc = build_run_configuration(root: dir)

      allow(ct).to receive(:mount).and_call_original

      rc.mount(force: true)

      expect(ct).to have_received(:mount).with(force: true)
    end
  end

  it 'builds the runtime rootfs from the init pid' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      identity = instance_double(OsCtld::ProcessIdentity, pid: 4321, close: nil)
      allow(OsCtld::ProcessIdentity).to receive(:new)
        .with(4321, namespaces: [:mnt], root: true)
        .and_return(identity)

      rc.init_pid = 4321

      expect(rc.runtime_rootfs).to eq('/proc/4321/root')
    end
  end

  it 'anchors and leases the exact init identity for the run' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      retained = instance_double(OsCtld::ProcessIdentity, pid: 4321, close: nil)
      copy = instance_double(OsCtld::ProcessIdentity, close: nil)
      allow(retained).to receive(:duplicate).and_return(copy)
      allow(OsCtld::ProcessIdentity).to receive(:new)
        .with(4321, namespaces: [:mnt], root: true)
        .and_return(retained)

      rc.init_pid = 4321
      lease = rc.acquire_init_lease

      expect(lease.identity).to be(copy)
      expect(copy).not_to have_received(:close)
      lease.close
      expect(copy).to have_received(:close)
    end
  end

  it 'waits for active leases during retirement without holding the run lock' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      retained = instance_double(OsCtld::ProcessIdentity, pid: 4321, close: nil)
      copy = instance_double(OsCtld::ProcessIdentity, close: nil)
      allow(retained).to receive(:duplicate).and_return(copy)
      allow(OsCtld::ProcessIdentity).to receive(:new)
        .with(4321, namespaces: [:mnt], root: true)
        .and_return(retained)
      rc.init_pid = 4321
      lease = rc.acquire_init_lease
      rc.begin_retirement
      completed = Queue.new

      destroy_thread = Thread.new do
        rc.destroy
        completed << true
      end

      10_000.times do
        break if destroy_thread.status == 'sleep'

        Thread.pass
      end

      expect(destroy_thread.status).to eq('sleep')
      expect(rc.init_pid).to eq(4321)
      expect { completed.pop(true) }.to raise_error(ThreadError)
      expect { rc.acquire_init_lease }
        .to raise_error(described_class::LifecycleError, 'container run is retiring')

      lease.close
      expect(destroy_thread.join(1)).to be(destroy_thread)
      expect(completed.pop).to be(true)
      expect(retained).to have_received(:close)
    ensure
      lease&.close
      destroy_thread&.join(1)
    end
  end

  [true, false].each do |alive|
    it "clears stopped-run identity only when pinned init is dead (alive=#{alive})" do
      with_tmpdir do |dir|
        _ct, rc = build_run_configuration(root: dir)
        identity = instance_double(OsCtld::ProcessIdentity, pid: 4321, alive?: alive, close: nil)
        copy = instance_double(OsCtld::ProcessIdentity, close: nil)
        allow(identity).to receive(:duplicate).and_return(copy)
        allow(OsCtld::ProcessIdentity).to receive(:new).and_return(identity)
        rc.init_pid = 4321
        lease = rc.acquire_init_lease

        expect(rc.clear_dead_init_identity).to be(!alive)
        expect(rc.init_pid).to eq(alive ? 4321 : nil)
        if alive
          expect(identity).not_to have_received(:close)
        else
          expect(identity).to have_received(:close)
        end
        expect(copy).not_to have_received(:close)
        lease.close
        expect(copy).to have_received(:close)
      ensure
        lease&.close
      end
    end
  end

  it 'closes a replaced init identity' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      first = instance_double(OsCtld::ProcessIdentity, pid: 4321, close: nil)
      second = instance_double(OsCtld::ProcessIdentity, pid: 4322, close: nil)
      allow(OsCtld::ProcessIdentity).to receive(:new).and_return(first, second)

      rc.init_pid = 4321
      rc.init_pid = 4322

      expect(rc.init_pid).to eq(4322)
      expect(first).to have_received(:close)
      expect(second).not_to have_received(:close)
    end
  end

  it 'installs independent retained descriptors without resolving the PID again' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      original = OsCtld::ProcessIdentity.new(Process.pid, namespaces: [:mnt], root: true)
      allow(OsCtld::ProcessIdentity).to receive(:new).and_call_original

      rc.retain_init_identity(original)
      lease = rc.acquire_init_lease
      original.close
      expect(OsCtld::ProcessIdentity).not_to have_received(:new)
      expect(lease.identity.alive?).to be(true)
      expect(lease.identity.root_dir.closed?).to be(false)
      lease.close
      rc.destroy
    ensure
      original&.close
      lease&.close
    end
  end

  it 'refuses retained installation before duplicating a retired run' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      original = instance_double(OsCtld::ProcessIdentity)
      rc.begin_retirement
      allow(original).to receive(:duplicate)

      expect { rc.retain_init_identity(original) }.to raise_error(described_class::LifecycleError)
      expect(original).not_to have_received(:duplicate)
    end
  end

  it 'closes an uninstalled duplicate on failure while preserving caller ownership' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      copy = instance_double(OsCtld::ProcessIdentity, pid: 4321, close: nil)
      original = instance_double(OsCtld::ProcessIdentity, duplicate: copy, close: nil)
      allow(rc).to receive(:exclusively).and_raise(described_class::LifecycleError, 'installation failed')

      expect { rc.retain_init_identity(original) }.to raise_error(described_class::LifecycleError)
      expect(copy).to have_received(:close)
      expect(original).not_to have_received(:close)
      expect(rc.init_pid).to be_nil
    end
  end

  [false, true].each do |retire|
    it "waits for leases and closes rejected replacement descriptors (retire=#{retire})" do
      with_tmpdir do |dir|
        _ct, rc = build_run_configuration(root: dir)
        first = instance_double(OsCtld::ProcessIdentity, pid: 4321, close: nil)
        leased = instance_double(OsCtld::ProcessIdentity, close: nil)
        original = instance_double(OsCtld::ProcessIdentity)
        replacement = instance_double(OsCtld::ProcessIdentity, pid: 4322, close: nil)
        allow(OsCtld::ProcessIdentity).to receive(:new).and_return(first)
        allow(first).to receive(:duplicate).and_return(leased)
        copied = OsCtl::Lib::Queue.new
        allow(original).to receive(:duplicate) {
          copied << true
          replacement
        }
        rc.init_pid = 4321
        lease = rc.acquire_init_lease
        result = OsCtl::Lib::Queue.new
        worker = Thread.new do
          rc.retain_init_identity(original)
          result << :installed
        rescue described_class::LifecycleError
          result << :retired
        end
        expect(copied.pop(timeout: 1)).to be(true)
        expect(rc.init_pid).to eq(4321)
        expect(result.pop(timeout: 0)).to be_nil
        rc.begin_retirement if retire
        lease.close
        expect(result.pop(timeout: 1)).to eq(retire ? :retired : :installed)
        expect(worker.join(1)).to eq(worker)
        expect(rc.init_pid).to eq(retire ? 4321 : 4322)
        if retire
          expect(replacement).to have_received(:close)
          expect(first).not_to have_received(:close)
        else
          expect(first).to have_received(:close)
          expect(replacement).not_to have_received(:close)
        end
      ensure
        lease&.close
        worker&.join(1)
      end
    end
  end

  describe 'authenticated impermanent root import' do
    def legacy_import(root:, suffix: 'impermanence-4014fb', correct: false, metadata: {}, ordinary: false, origin: '-')
      ct = build_run_config_container(root:, id: 'niximpermanent', distribution: 'nixos',
                                      version: '24.05', vendor: 'vpsadminos', variant: 'impermanence')
      ct.define_singleton_method(:payload_cgroup_path) { File.join(cgroup_path, "lxc.payload.#{id}") }
      rc = described_class.new(ct, load_conf: false)
      rc.save
      path = File.join(ct.pool.ct_dir, ct.id, 'config.yml')
      File.chmod(0o600, path)
      cfg = load_yaml_file(path).merge('id' => {
        'pool_name' => 'tank', 'container_id' => ct.id, 'timestamp' => 1_792_700_667.9359279
      }, 'future_field' => 'preserved').merge(metadata)
      candidate = ordinary ? ct.dataset.name : "#{ct.dataset.name}.#{suffix}"
      cfg.merge!('dataset' => candidate, 'destroy_dataset_on_stop' => true) if correct
      write_yaml_file(path, cfg)
      gc_path = File.join(ct.pool.conf_path, 'pool', 'garbage-collector.yml')
      FileUtils.mkdir_p(File.dirname(gc_path))
      records = ordinary ? [] : [{ 'run_id' => cfg['id'], 'dataset' => candidate }]
      write_yaml_file(gc_path, 'container_run_datasets' => records)
      gc = OsCtld::GarbageCollector.new(ct.pool)
      ct.pool.define_singleton_method(:garbage_collector) { gc }
      rc = described_class.load(ct)

      mountpoint = File.join(root, 'temporary-root')
      FileUtils.mkdir_p(File.join(mountpoint, 'private'))
      held_root = File.open(File.join(mountpoint, 'private'))
      device = "#{held_root.stat.dev_major}:#{held_root.stat.dev_minor}"
      mountinfo = "739 684 #{device} /private / rw,idmapped - zfs #{candidate} rw\n"
      stat_fields = Array.new(20, '0')
      stat_fields[19] = '60064'
      process_stat = "6498 (init (retained)) #{stat_fields.join(' ')}\n"
      installed = instance_double(OsCtld::ProcessIdentity, pid: 6498, close: nil)
      identity = instance_double(OsCtld::ProcessIdentity, pid: 6498, root_dir: held_root, close: nil,
                                                          authenticate!: nil, duplicate: installed)
      allow(identity).to receive(:read_proc_file).with('mountinfo').and_return(mountinfo)
      allow(identity).to receive(:read_proc_file).with('stat').and_return(process_stat)
      allow(identity).to receive(:read_proc_file).with('status').and_return("NSpid:\t6498\t1\n")
      allow(OsCtld::ProcessIdentity).to receive(:new).with(6498, namespaces: [:mnt], root: true).and_return(identity)
      zfs = "#{candidate}\t5076182134290402100\t#{mountpoint}\tyes\t#{origin}\n"
      allow(rc).to receive(:syscmd_argv).and_return(Struct.new(:output).new(zfs))
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with('/proc/self/mountinfo')
                                   .and_return("682 74 #{device} / #{mountpoint} rw - zfs #{candidate} rw\n")
      { ct:, rc:, path:, cfg:, gc:, gc_path:, candidate:, identity:, installed:, held_root:, mountinfo:, zfs: }
    end

    %i[absent empty unrelated clone].each do |kind|
      it "preserves an authenticated ordinary base run with #{kind} GC/origin state after enabling impermanence" do
        with_tmpdir do |root|
          f = legacy_import(root:, ordinary: true, origin: kind == :clone ? 'tank/source@snapshot' : '-')
          if kind == :absent
            File.unlink(f[:gc_path])
          elsif kind == :unrelated
            rows = [{ 'run_id' => f[:cfg]['id'].merge('container_id' => 'other'), 'dataset' => 'tank/ct/other.impermanence-123abc' }]
            write_yaml_file(f[:gc_path], 'container_run_datasets' => rows)
            gc = OsCtld::GarbageCollector.new(f[:ct].pool)
            f[:ct].pool.define_singleton_method(:garbage_collector) { gc }
            f[:gc] = gc
          end
          bytes = File.binread(f[:path])
          stat = File.stat(f[:path])
          gc_bytes = File.binread(f[:gc_path]) if File.exist?(f[:gc_path])
          original_dataset = f[:rc].dataset
          published = false

          f[:rc].recover_impermanent_root!(6498, publish: lambda {
            expect(f[:identity]).not_to have_received(:close)
            expect(f[:rc].init_pid).to eq(6498)
            published = true
          }) do
            expect(f[:identity]).to have_received(:authenticate!).once
            expect(f[:rc].dataset).to be(original_dataset)
            expect(f[:rc].destroy_dataset_on_stop?).to be(false)
          end

          expect(published).to be(true)
          expect(File.binread(f[:path])).to eq(bytes)
          expect(File.stat(f[:path]).ino).to eq(stat.ino)
          expect(f[:rc].run_id.dump).to eq(f[:cfg]['id'])
          expect(f[:rc].dataset).to be(original_dataset)
          expect(f[:rc].destroy_dataset_on_stop?).to be(false)
          expect(File.exist?(f[:gc_path]) ? File.binread(f[:gc_path]) : nil).to eq(gc_bytes)
          expect(f[:gc].instance_variable_get('@retirement_inhibited')).to be(false)
          expect(f[:identity]).to have_received(:authenticate!).twice
          expect(OsCtld::ProcessIdentity).to have_received(:new).once
          expect(f[:identity]).to have_received(:close)
          expect(f[:installed]).not_to have_received(:close)
        ensure
          f&.dig(:held_root)&.close
        end
      end
    end

    %i[same_run overlap cleanup temporary_without_owner].each do |kind|
      it "refuses #{kind} instead of accepting an unauthenticated ordinary base run" do
        with_tmpdir do |root|
          f = legacy_import(root:, ordinary: kind != :temporary_without_owner)
          rows = case kind
                 when :same_run then [{ 'run_id' => f[:cfg]['id'], 'dataset' => "#{f[:candidate]}.impermanence-123abc" }]
                 when :overlap then [{ 'run_id' => f[:cfg]['id'].merge('container_id' => 'other'), 'dataset' => 'tank/ct' }]
                 else []
                 end
          write_yaml_file(f[:gc_path], 'container_run_datasets' => rows)
          gc = OsCtld::GarbageCollector.new(f[:ct].pool)
          f[:ct].pool.define_singleton_method(:garbage_collector) { gc }
          if kind == :cleanup
            f[:cfg]['destroy_dataset_on_stop'] = true
            write_yaml_file(f[:path], f[:cfg])
            f[:rc] = described_class.load(f[:ct])
          end
          bytes = File.binread(f[:path])
          expect { f[:rc].recover_impermanent_root!(6498, publish: -> { raise 'unexpected publication' }) }
            .to raise_error(OsCtld::ConfigError)
          expect(File.binread(f[:path])).to eq(bytes)
        ensure
          f&.dig(:held_root)&.close
        end
      end
    end

    %i[gc_appearance gc_disappearance ownership root process file].each do |change|
      it "rejects a #{change} change during preparation of an ordinary base run" do
        with_tmpdir do |root|
          f = legacy_import(root:, ordinary: true)
          File.unlink(f[:gc_path]) if change == :gc_appearance
          bytes = File.binread(f[:path])
          expect do
            f[:rc].recover_impermanent_root!(6498, publish: -> { raise 'unexpected publication' }) do
              case change
              when :gc_appearance then write_yaml_file(f[:gc_path], 'container_run_datasets' => [])
              when :gc_disappearance then File.unlink(f[:gc_path])
              when :ownership
                run = Struct.new(:run_id).new(OsCtld::Container::RunId.load(f[:cfg]['id'].merge('container_id' => 'other')))
                f[:gc].add_container_run_dataset(run, OsCtl::Lib::Zfs::Dataset.new('tank/ct/other.impermanence-123abc'))
              when :root then allow(f[:identity]).to receive(:read_proc_file).with('mountinfo').and_return('')
              when :process then allow(f[:identity]).to receive(:authenticate!).and_raise(Errno::ESRCH)
              when :file then File.write(f[:path], "#{bytes}# external edit\n")
              end
            end
          end.to raise_error(OsCtld::ConfigError)
          expect(f[:rc].dataset.name).to eq(f[:ct].dataset.name)
          expect(f[:rc].destroy_dataset_on_stop?).to be(false)
          expect(f[:rc].init_pid).to be_nil
          expect(f[:identity]).to have_received(:close)
          expect(f[:installed]).to have_received(:close)
        ensure
          f&.dig(:held_root)&.close
        end
      end
    end

    it 'repairs the captured stale-base state only after preparation, preserving ID, fields and GC bytes' do
      with_tmpdir do |root|
        fixture = legacy_import(root:)
        rc = fixture[:rc]
        original = File.binread(fixture[:path])
        gc_bytes = File.binread(fixture[:gc_path])
        published = false
        publish = lambda do
          expect(rc.init_pid).to eq(6498)
          expect(fixture[:identity]).not_to have_received(:close)
          expect(load_yaml_file(fixture[:path])).to eq(fixture[:cfg].merge(
                                                         'dataset' => fixture[:candidate], 'destroy_dataset_on_stop' => true
                                                       ))
          published = true
        end
        rc.recover_impermanent_root!(6498, publish:) do
          expect(rc.dataset.name).to eq(fixture[:candidate])
          expect(File.binread(fixture[:path])).to eq(original)
        end
        expect(published).to be(true)
        expect(File.binread(fixture[:gc_path])).to eq(gc_bytes)
        expect(OsCtld::ProcessIdentity).to have_received(:new).once
        expect(fixture[:identity]).to have_received(:close)
        expect(fixture[:installed]).not_to have_received(:close)
        reloaded = described_class.load(fixture[:ct])
        expect(reloaded.dataset.name).to eq(fixture[:candidate])
        expect(reloaded.run_id).to eq(rc.run_id)
        expect(reloaded.destroy_dataset_on_stop?).to be(true)
      ensure
        fixture&.dig(:held_root)&.close
      end
    end

    it 'keeps the real reader installed identity when DB insertion succeeds but its event fails' do
      with_tmpdir do |root|
        f = legacy_import(root:)
        ct = f[:ct]
        rc = f[:rc]
        ct.extend(OsCtld::Manipulable)
        ct.init_manipulable
        ct.define_singleton_method(:run_conf) { rc }
        ct.define_singleton_method(:impermanence) { true }
        ct.singleton_class.attr_accessor(:state)
        pool = OsCtld::Pool.new('tank', 'tank')
        pool.instance_variable_set('@garbage_collector', f[:gc])
        allow(pool).to receive(:load_entity).and_return(ct)
        allow(pool).to receive(:ensure_limits)
        allow(pool).to receive(:prepare_container)
        stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
          def self.run!(*, **); end
        end)
        allow(OsCtld::ContainerControl::Commands::State).to receive(:run!)
          .and_return(Struct.new(:state, :init_pid).new(:running, 6498))
        stub_const('OsCtld::DB::Containers', Class.new do
          def self.add(_ct); end
          def self.find(*); end
        end)
        published = nil
        allow(OsCtld::DB::Containers).to receive(:add) do |object|
          published = object
          raise 'event failed after insertion'
        end
        allow(OsCtld::DB::Containers).to receive(:find) { published }
        allow(pool).to receive(:log)
        gc_bytes = File.binread(f[:gc_path])

        pool.send(:load_container, ct.id, nil)

        expect(pool).to have_received(:log).with(:fatal, /attachment incomplete.*remains managed.*reclamation is inhibited/)
        expect(published).to be(ct)
        expect(ct.run_conf).to be(rc)
        expect(rc.init_pid).to eq(6498)
        expect(f[:identity]).to have_received(:close)
        expect(f[:installed]).not_to have_received(:close)
        expect(File.binread(f[:gc_path])).to eq(gc_bytes)
        expect(f[:gc].instance_variable_get('@retirement_inhibited')).to be(true)
        expect(load_yaml_file(f[:path])).to eq(f[:cfg].merge(
                                                 'dataset' => f[:candidate], 'destroy_dataset_on_stop' => true
                                               ))
      ensure
        f&.dig(:held_root)&.close
      end
    end

    %w[impermanence-4014fb boot-123abc].each do |suffix|
      it "authenticates a complete saved #{suffix} selection without rewriting it" do
        with_tmpdir do |root|
          fixture = legacy_import(root:, suffix:, correct: true)
          input = File.stat(fixture[:path])
          bytes = File.binread(fixture[:path])
          fixture[:rc].recover_impermanent_root!(6498, publish: -> {})
          expect(File.stat(fixture[:path]).ino).to eq(input.ino)
          expect(File.binread(fixture[:path])).to eq(bytes)
        ensure
          fixture&.dig(:held_root)&.close
        end
      end
    end

    {
      missing_id: ->(f) { f[:cfg].delete('id') },
      missing_field: ->(f) { f[:cfg].delete('distribution') },
      foreign_id: ->(f) { f[:cfg]['id']['container_id'] = 'foreign' },
      invalid_time: ->(f) { f[:cfg]['id']['timestamp'] = 0 },
      conflicting_dataset: ->(f) { f[:cfg]['dataset'] = 'tank/ct/foreign' },
      wrong_cleanup: ->(f) { f[:cfg]['destroy_dataset_on_stop'] = 'true' }
    }.each do |name, change|
      it "refuses #{name} without publishing, changing YAML or retiring ownership" do
        with_tmpdir do |root|
          fixture = legacy_import(root:)
          change.call(fixture)
          write_yaml_file(fixture[:path], fixture[:cfg])
          rc = described_class.load(fixture[:ct])
          before = File.binread(fixture[:path])
          gc_bytes = File.binread(fixture[:gc_path])
          published = false
          expect { rc.recover_impermanent_root!(6498, publish: -> { published = true }) }
            .to raise_error(OsCtld::ConfigError)
          expect(published).to be(false)
          expect(File.binread(fixture[:path])).to eq(before)
          expect(File.binread(fixture[:gc_path])).to eq(gc_bytes)
        ensure
          fixture&.dig(:held_root)&.close
        end
      end
    end

    %i[file gc mount birth pid_reuse root zfs process namespace preparation publication].each do |change|
      it "refuses a #{change} change/failure before publication and releases its retained descriptors" do
        with_tmpdir do |root|
          fixture = legacy_import(root:)
          rc = fixture[:rc]
          before = File.binread(fixture[:path])
          gc_bytes = File.binread(fixture[:gc_path])
          publish = -> { raise OsCtld::ConfigError, 'host-link publication refused' } if change == :publication
          publish ||= -> { raise 'unexpected publication' }
          expect do
            rc.recover_impermanent_root!(6498, publish:) do
              case change
              when :file then File.write(fixture[:path], "#{before}# external edit\n")
              when :gc then File.write(fixture[:gc_path], "#{gc_bytes}# external edit\n")
              when :mount then allow(fixture[:identity]).to receive(:read_proc_file).with('mountinfo').and_return('')
              when :birth then allow(fixture[:identity]).to receive(:read_proc_file).with('stat').and_return('')
              when :pid_reuse then allow(fixture[:identity]).to receive(:read_proc_file).with('status').and_return("NSpid:\t6498\t42\n")
              when :root then File.rename(File.join(root, 'temporary-root', 'private'), File.join(root, 'old-root'))
                              FileUtils.mkdir_p(File.join(root, 'temporary-root', 'private'))
              when :zfs then allow(rc).to receive(:syscmd_argv).and_return(Struct.new(:output).new(fixture[:zfs].sub('5076182134290402100', '5076182134290402101')))
              when :process then allow(fixture[:identity]).to receive(:authenticate!).and_raise(Errno::ESRCH)
              when :namespace then allow(fixture[:identity]).to receive(:authenticate!).and_raise(Errno::ESTALE)
              when :preparation then raise OsCtld::ConfigError, 'preparation refused'
              end
            end
          end.to raise_error(OsCtld::ConfigError)
          expect(File.binread(fixture[:path])).to eq(before) unless %i[file publication].include?(change)
          expect(File.binread(fixture[:gc_path])).to eq(gc_bytes) unless change == :gc
          expect(rc.dataset.name).to eq(fixture[:ct].dataset.name)
          expect(rc.init_pid).to be_nil
          expect(fixture[:identity]).to have_received(:close)
          expect(fixture[:installed]).to have_received(:close) unless change == :preparation
        ensure
          fixture&.dig(:held_root)&.close
        end
      end
    end

    %i[missing duplicate alias ancestor_alias descendant_alias descendant old_run].each do |kind|
      it "rejects #{kind} GC ownership without guessing or registering a root" do
        with_tmpdir do |root|
          fixture = legacy_import(root:)
          rows = load_yaml_file(fixture[:gc_path])['container_run_datasets']
          case kind
          when :missing then rows.clear
          when :duplicate then rows << Marshal.load(Marshal.dump(rows.first))
          when :alias then rows << { 'run_id' => rows.first['run_id'].merge('container_id' => 'foreign'), 'dataset' => fixture[:candidate] }
          when :ancestor_alias then rows << { 'run_id' => rows.first['run_id'].merge('container_id' => 'foreign'), 'dataset' => 'tank/ct' }
          when :descendant_alias then rows << { 'run_id' => rows.first['run_id'].merge('container_id' => 'foreign'), 'dataset' => "#{fixture[:candidate]}/child" }
          when :descendant then rows.first['dataset'] += '/child'
          when :old_run then rows.first['run_id']['timestamp'] -= 1
          end
          write_yaml_file(fixture[:gc_path], 'container_run_datasets' => rows)
          gc = OsCtld::GarbageCollector.new(fixture[:ct].pool)
          fixture[:ct].pool.define_singleton_method(:garbage_collector) { gc }
          bytes = File.binread(fixture[:gc_path])
          expect { fixture[:rc].recover_impermanent_root!(6498, publish: -> { raise 'unexpected publication' }) }
            .to raise_error(OsCtld::ConfigError)
          expect(File.binread(fixture[:gc_path])).to eq(bytes)
          if %i[missing old_run].include?(kind)
            expect(OsCtld::ProcessIdentity).to have_received(:new).once
          else
            expect(OsCtld::ProcessIdentity).not_to have_received(:new)
          end
        ensure
          fixture&.dig(:held_root)&.close
        end
      end
    end

    ['', "---\n", "---\n[]\n", "---\n[\n"].each do |bytes|
      it "rejects malformed/empty runtime bytes #{bytes.inspect}" do
        with_tmpdir do |root|
          fixture = legacy_import(root:)
          File.write(fixture[:path], bytes)
          expect { described_class.load(fixture[:ct]) }.to raise_error(OsCtld::ConfigError)
          expect(File.binread(fixture[:path])).to eq(bytes)
        ensure
          fixture&.dig(:held_root)&.close
        end
      end
    end
  end

  it 'retires the init identity and prevents late installation after destroy' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      identity = instance_double(OsCtld::ProcessIdentity, pid: 4321, close: nil)
      allow(OsCtld::ProcessIdentity).to receive(:new)
        .with(4321, namespaces: [:mnt], root: true)
        .and_return(identity)

      rc.init_pid = 4321
      rc.destroy

      expect(rc.init_pid).to be_nil
      expect(identity).to have_received(:close)
      expect do
        rc.init_pid = 4322
      end.to raise_error(
        described_class::LifecycleError,
        'container run is retiring'
      )
      expect(OsCtld::ProcessIdentity).not_to have_received(:new).with(4322)
    end
  end

  it 'tracks abort and reboot state' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)

      expect(rc.aborted?).to be(false)
      expect(rc.reboot?).to be(false)

      rc.aborted = true
      rc.request_reboot

      expect(rc.aborted?).to be(true)
      expect(rc.reboot?).to be(true)
    end
  end

  it 'fulfils exit promises' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      promise = rc.get_exit_promise

      rc.fulfil_exit

      expect(promise.wait(timeout: 0.1)).to be(true)
    end
  end

  it 'reports whether distribution network configuration should run' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)

      expect(rc.dist_configure_network?).to be(true)

      rc.dist_network_configured = true

      expect(rc.dist_configure_network?).to be(false)
    end
  end

  it 'returns false from dist_configure_network? when the container cannot configure networking' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir, can_dist_configure_network: false)

      expect(rc.dist_configure_network?).to be(false)
    end
  end

  it 'ignores missing runtime config files on destroy' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)

      expect { rc.destroy }.not_to raise_error
    end
  end
end
