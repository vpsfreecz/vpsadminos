# frozen_string_literal: true

# rubocop:disable Lint/ConstantDefinitionInBlock, Lint/UnusedBlockArgument, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/LeakyConstantDeclaration, RSpec/MessageSpies, RSpec/VerifiedDoubles

require 'stringio'
require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/manipulable'
require 'osctld/utils/container'

module OsCtld
  module Commands
    module User; end
  end
end

require 'osctld/commands/container/create'
require 'osctld/commands/container/create_empty'
require 'osctld/commands/container/import'
require 'osctld/commands/container/copy'
require 'osctld/commands/container/move'
require 'osctld/commands/container/reinstall'
require 'osctld/commands/container/map_mode'
require 'osctld/commands/container/chown'
require 'osctld/commands/container/chgrp'

RSpec.describe 'container provisioning commands' do
  def stub_db
    stub_const('OsCtld::DB::Pools', Class.new do
      def self.get_or_default(_pool); end
    end)
    stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    stub_const('OsCtld::DB::Users', Class.new do
      def self.find(_name, _pool); end
    end)
    stub_const('OsCtld::DB::Groups', Class.new do
      def self.find(_name, _pool); end

      def self.default(_pool); end
    end)
  end

  def stub_history
    stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
  end

  def build_pool(name: 'tank', active: true)
    Struct.new(:name, :active_state) do
      def active?
        active_state
      end
    end.new(name, active)
  end

  def lockable(obj)
    obj.define_singleton_method(:acquire_manipulation_lock) do |_holder, block: false|
      true
    end
    obj.define_singleton_method(:release_manipulation_lock) do
      nil
    end
    obj
  end

  def without_residual_generations(obj)
    lifecycle =
      Struct.new(:residuals, :runtime_generations).new([], [])
    obj.define_singleton_method(:lifecycle) { lifecycle }
    obj
  end

  def with_runtime_generation(obj, role:)
    run_id = OsCtld::Container::RunId.new(
      pool_name: 'tank',
      container_id: 'ct1'
    )
    lifecycle = Struct.new(:runtime_generations).new(
      [{ 'id' => run_id.dump, 'role' => role }]
    )
    obj.define_singleton_method(:lifecycle) { lifecycle }
    obj
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
    allow(stub_history).to receive(:log)
  end

  describe OsCtld::Commands::Container::Create do
    before do
      stub_db
    end

    it 'validates required image metadata before fetching the image' do
      pool = build_pool
      allow(OsCtld::DB::Containers).to receive(:find).with('ct1', pool).and_return(nil)
      command = described_class.new({ id: 'ct1', image: { distribution: 'almalinux' } }, {})

      expect { command.execute(pool) }
        .to raise_error(OsCtld::CommandFailed, 'provide distribution version')
    end

    it 'fetches the image and delegates creation to the import command' do
      import_class = stub_const('OsCtld::Commands::Container::Import', Class.new)
      pool = build_pool
      command = described_class.new(
        {
          id: 'ct1',
          user: 'alice',
          group: '/default',
          dataset: 'tank/custom',
          zfs_properties: { compression: 'lz4' },
          map_mode: 'zfs',
          image: {
            distribution: 'almalinux',
            version: '9',
            arch: 'x86_64'
          }
        },
        {}
      )
      allow(OsCtld::DB::Containers).to receive(:find).with('ct1', pool).and_return(nil)
      allow(OsCtld::DB::Users).to receive(:find).with('alice', pool).and_return(Object.new)
      allow(OsCtld::DB::Groups).to receive(:find).with('/default', pool).and_return(Object.new)
      allow(command).to receive(:get_repositories).with(pool).and_return([:default])
      allow(command).to receive(:with_repository_image_path!) do |repos, image, &block|
        expect(repos).to eq([:default])
        expect(image).to eq(command.opts[:image])
        block.call('/tmp/image.tar')
      end
      allow(command).to receive(:call_cmd!).with(
        import_class,
        pool: 'tank',
        as_id: 'ct1',
        as_user: 'alice',
        as_group: '/default',
        dataset: 'tank/custom',
        zfs_properties: { compression: 'lz4' },
        map_mode: 'zfs',
        file: '/tmp/image.tar'
      ).and_return(status: true, output: nil)

      expect(command.execute(pool)).to eq(status: true, output: nil)
    end
  end

  describe OsCtld::Commands::Container::CreateEmpty do
    let(:pool) { build_pool }

    before do
      stub_db
    end

    it 'rejects an explicit group that cannot be found' do
      allow(OsCtld::DB::Pools).to receive(:get_or_default).with('tank').and_return(pool)
      allow(OsCtld::DB::Containers).to receive(:find).with('ct1', pool).and_return(nil)
      allow(OsCtld::DB::Users).to receive(:find).with('alice', pool).and_return(Object.new)
      allow(OsCtld::DB::Groups).to receive(:find).with('/missing', pool).and_return(nil)
      command = described_class.new(
        { id: 'ct1', pool: 'tank', user: 'alice', group: '/missing', distribution: 'almalinux', version: '9', arch: 'x86_64' },
        {}
      )

      expect { command.find }
        .to raise_error(OsCtld::CommandFailed, 'group not found')
    end

    it 'creates a user on demand and uses the default group' do
      user_create_class = stub_const('OsCtld::Commands::User::Create', Class.new)
      builder_class = stub_const('OsCtld::Container::Builder', Class.new do
        def self.create(*); end
      end)
      group = Object.new
      user = Object.new
      builder = instance_double(builder_class, valid?: true, errors: [])
      allow(OsCtld::DB::Pools).to receive(:get_or_default).with('tank').and_return(pool)
      allow(OsCtld::DB::Containers).to receive(:find).with('ct1', pool).and_return(nil)
      allow(OsCtld::DB::Users).to receive(:find).with('ct1', pool).and_return(nil, user)
      allow(OsCtld::DB::Groups).to receive(:default).with(pool).and_return(group)
      allow(builder_class).to receive(:create).and_return(builder)
      command = described_class.new(
        { id: 'ct1', pool: 'tank', distribution: 'almalinux', version: '9', arch: 'x86_64' },
        {}
      )
      allow(command).to receive(:call_cmd!).with(
        user_create_class,
        pool: 'tank',
        name: 'ct1',
        standalone: false
      ).and_return(status: true, output: nil)

      expect(command.find).to equal(builder)
      expect(builder_class).to have_received(:create).with(
        pool,
        'ct1',
        user,
        group,
        nil,
        cmd: command
      )
    end

    it 'cleans up the builder on provisioning failures' do
      ct = Struct.new do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new
      ctrc = Struct.new(:ct, :map_mode).new(ct, 'native')
      builder = double(
        'builder',
        ctrc:,
        register: true,
        create_root_dataset: nil,
        shift_or_mount_dataset: nil,
        configure: nil,
        setup_ct_dir: nil,
        setup_lxc_home: nil,
        setup_lxc_configs: nil,
        setup_log_file: nil,
        setup_user_hook_script_dir: nil,
        monitor: nil,
        cleanup: nil
      )
      allow(builder).to receive(:create_root_dataset).and_raise('boom')
      command = described_class.new({ distribution: 'almalinux', version: '9', arch: 'x86_64' }, {})
      allow(command).to receive(:progress)

      expect { command.execute(builder) }.to raise_error(RuntimeError, 'boom')
      expect(builder).to have_received(:cleanup).with(dataset: true)
    end
  end

  describe OsCtld::Commands::Container::Import do
    let(:pool) { build_pool }

    before do
      stub_db
    end

    it 'rejects disabled pools' do
      expect { described_class.new({}, {}).execute(build_pool(active: false)) }
        .to raise_error(OsCtld::CommandFailed, 'the pool is disabled')
    end

    it 'cleans up partially imported containers when provisioning fails after registration' do
      builder_class = stub_const('OsCtld::Container::Builder', Class.new do
        def self.new(*); end
      end)
      importer_class = stub_const('OsCtld::Container::Importer', Class.new do
        def self.new(*); end
      end)
      devices = Struct.new do
        def check_all_available!; end

        def init; end
      end.new
      ct = Struct.new(:pool, :devices, :netifs, :state) do
        def new_run_conf
          :run_conf
        end

        def manipulate(_holder, block:, &)
          yield
        end

        def save_config; end
      end.new(pool, devices, [], nil)
      builder = instance_double(
        builder_class,
        valid?: true,
        errors: [],
        register: true,
        cleanup: nil,
        setup_lxc_home: nil,
        setup_ct_dir: nil,
        setup_rootfs: nil,
        setup_lxc_configs: nil,
        setup_log_file: nil,
        setup_user_hook_script_dir: nil,
        monitor: nil
      )
      importer = instance_double(
        importer_class,
        load_metadata: nil,
        has_ct_id?: true,
        ct_id: 'ct1',
        load_ct: ct,
        create_datasets: nil,
        import_all_datasets: nil,
        install_user_hook_scripts: nil
      )
      allow(builder_class).to receive(:new).and_return(builder)
      allow(importer_class).to receive(:new).and_return(importer)
      allow(OsCtld::DB::Containers).to receive(:find).with('ct1', pool).and_return(nil)
      allow(importer).to receive_messages(get_or_create_user: Object.new, get_or_create_group: Object.new)
      allow(importer).to receive(:create_datasets).and_raise('import failed')
      command = described_class.new({}, {})
      allow(command).to receive(:progress)

      expect do
        command.send(:import, pool, StringIO.new('image'), '/tmp/image.tar')
      end.to raise_error(RuntimeError, 'import failed')
      expect(builder).to have_received(:cleanup).with(dataset: true)
    end

    it 'uses explicit user and group overrides when loading the container' do
      dataset_class = stub_const('OsCtl::Lib::Zfs::Dataset', Class.new do
        def self.new(*); end
      end)
      builder_class = stub_const('OsCtld::Container::Builder', Class.new do
        def self.new(*); end
      end)
      importer_class = stub_const('OsCtld::Container::Importer', Class.new do
        def self.new(*); end
      end)
      user = Object.new
      group = Object.new
      ct = Struct.new(:pool, :devices, :netifs, :state) do
        def new_run_conf
          :run_conf
        end

        def manipulate(_holder, block:, &)
          yield
        end

        def save_config; end
      end.new(
        pool,
        Struct.new do
          def remove_missing; end

          def init; end
        end.new,
        [],
        nil
      )
      builder = instance_double(
        builder_class,
        valid?: true,
        errors: [],
        register: true,
        cleanup: nil,
        setup_lxc_home: nil,
        setup_ct_dir: nil,
        setup_rootfs: nil,
        setup_lxc_configs: nil,
        setup_log_file: nil,
        setup_user_hook_script_dir: nil,
        monitor: nil
      )
      importer = instance_double(
        importer_class,
        load_metadata: nil,
        has_ct_id?: true,
        ct_id: 'ct1',
        load_ct: ct,
        create_datasets: nil,
        import_all_datasets: nil,
        install_user_hook_scripts: nil
      )
      dataset = Object.new
      allow(dataset_class).to receive(:new).with('tank/custom', base: 'tank/custom').and_return(dataset)
      allow(builder_class).to receive(:new).and_return(builder)
      allow(importer_class).to receive(:new).and_return(importer)
      allow(OsCtld::DB::Containers).to receive(:find).with('ct1', pool).and_return(nil)
      allow(OsCtld::DB::Users).to receive(:find).with('alice', pool).and_return(user)
      allow(OsCtld::DB::Groups).to receive(:find).with('/default', pool).and_return(group)
      command = described_class.new(
        {
          as_user: 'alice',
          as_group: '/default',
          dataset: 'tank/custom',
          map_mode: 'zfs',
          missing_devices: 'remove'
        },
        {}
      )

      expect(command.send(:import, pool, StringIO.new('image'), '/tmp/image.tar')).to eq(
        status: true,
        output: nil
      )
      expect(importer).to have_received(:load_ct).with(
        id: 'ct1',
        user: user,
        group: group,
        dataset: dataset,
        ct_opts: {
          map_mode: 'zfs',
          devices: false,
          staged: true
        }
      )
    end
  end

  describe OsCtld::Commands::Container::Copy do
    it 'runs split copy steps from config through cleanup' do
      config_class = stub_const('OsCtld::Commands::Container::CopyConfig', Class.new)
      rootfs_class = stub_const('OsCtld::Commands::Container::CopyRootfs', Class.new)
      state_class = stub_const('OsCtld::Commands::Container::CopyState', Class.new)
      cleanup_class = stub_const('OsCtld::Commands::Container::CopyCleanup', Class.new)
      ct = without_residual_generations(Struct.new(:id, :pool) do
        def exclusively(&block)
          block.call
        end

        def manipulate(_holder, block:, &)
          yield
        end
      end.new('ct1', build_pool))
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          target_id: 'ct2',
          target_pool: 'dst',
          target_user: 'bob',
          target_group: 'web',
          target_dataset: 'dst/custom/ct2',
          network_interfaces: false,
          consistent: false,
          restart: false
        },
        {}
      )
      allow(command).to receive(:call_cmd!).with(
        config_class,
        id: 'ct1',
        pool: 'tank',
        target_id: 'ct2',
        target_pool: 'dst',
        target_user: 'bob',
        target_group: 'web',
        target_dataset: 'dst/custom/ct2',
        from_snapshot: nil,
        network_interfaces: false
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        rootfs_class,
        id: 'ct1',
        pool: 'tank'
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        state_class,
        id: 'ct1',
        pool: 'tank',
        consistent: false,
        restart: false
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        cleanup_class,
        id: 'ct1',
        pool: 'tank'
      ).and_return(status: true, output: nil)

      expect(command.execute(ct)).to eq(status: true, output: nil)
    end
  end

  describe OsCtld::Commands::Container::Move do
    it 'runs split move steps from config through cleanup' do
      config_class = stub_const('OsCtld::Commands::Container::MoveConfig', Class.new)
      rootfs_class = stub_const('OsCtld::Commands::Container::MoveRootfs', Class.new)
      state_class = stub_const('OsCtld::Commands::Container::MoveState', Class.new)
      cleanup_class = stub_const('OsCtld::Commands::Container::MoveCleanup', Class.new)
      ct = without_residual_generations(Struct.new(:id, :pool) do
        def exclusively(&block)
          block.call
        end

        def manipulate(_holder, block:, &)
          yield
        end
      end.new('ct1', build_pool))
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          target_id: 'ct2',
          target_pool: 'dst'
        },
        {}
      )
      allow(command).to receive(:call_cmd!).with(
        config_class,
        id: 'ct1',
        pool: 'tank',
        target_id: 'ct2',
        target_pool: 'dst',
        target_user: nil,
        target_group: nil,
        target_dataset: nil,
        network_interfaces: true
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        rootfs_class,
        id: 'ct1',
        pool: 'tank'
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        state_class,
        id: 'ct1',
        pool: 'tank',
        start: true
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        cleanup_class,
        id: 'ct1',
        pool: 'tank'
      ).and_return(status: true, output: nil)

      expect(command.execute(ct)).to eq(status: true, output: nil)
    end
  end

  describe OsCtld::Commands::Container::Reinstall do
    it 'fills missing remote image attributes from the container and rejects snapshots unless forced' do
      builder_class = stub_const('OsCtld::Container::Builder', Class.new do
        def self.new(*); end
      end)
      ct = without_residual_generations(
        Struct.new(:id, :pool, :distribution, :version, :arch, :vendor, :variant) do
          def running?
            false
          end

          def new_run_conf
            :run_conf
          end

          def manipulate(_holder, block:, &)
            yield
          end
        end.new(
          'ct1',
          build_pool,
          'almalinux',
          '9',
          'x86_64',
          'custom-vendor',
          'special'
        )
      )
      allow(builder_class).to receive(:new).and_return(Object.new)
      command = described_class.new({ type: 'remote', image: {} }, {})
      allow(command).to receive(:with_image_path) do |pool, type:, path:, image:, &block|
        expect(pool).to eq(ct.pool)
        expect(type).to eq('remote')
        expect(path).to be_nil
        expect(image).to eq(
          distribution: 'almalinux',
          version: '9',
          arch: 'x86_64',
          vendor: 'custom-vendor',
          variant: 'special'
        )
        block.call('/tmp/image.tar')
      end
      allow(command).to receive(:snapshots).with(ct).and_return(['tank/ct1@snap'])

      expect { command.execute(ct) }
        .to raise_error(OsCtld::CommandFailed, /the dataset has snapshots/)
    end

    it 'blocks reinstall while an active run is finalizing' do
      ct = with_runtime_generation(
        Struct.new(
          :id,
          :pool,
          :distribution,
          :version,
          :arch,
          :vendor,
          :variant
        ) do
          def running?
            false
          end

          def manipulate(_holder, block:, &)
            yield
          end
        end.new(
          'ct1',
          build_pool,
          'almalinux',
          '9',
          'x86_64',
          'default',
          'default'
        ),
        role: 'active'
      )

      expect do
        described_class.new({ type: 'remote', image: {} }, {}).execute(ct)
      end.to raise_error(
        OsCtld::CommandFailed,
        /container reinstall is blocked.*active/
      )
    end
  end

  describe OsCtld::Commands::Container::MapMode do
    before do
      stub_const('OsCtld::Container::MAP_MODES', %w[native zfs])
    end

    it 'rejects unsupported mapping modes' do
      ct = without_residual_generations(Struct.new(:map_mode) do
        def running?
          false
        end
      end.new('native'))

      expect { described_class.new({ map_mode: 'invalid' }, {}).execute(ct) }
        .to raise_error(OsCtld::CommandFailed, 'invalid map mode')
    end

    it 'converts native datasets to zfs mapping' do
      ds1 = Struct.new(:relative_name).new('rootfs')
      ds2 = Struct.new(:relative_name).new('data')
      uid_map = [double(to_s: '0:100000:65536')]
      gid_map = [double(to_s: '0:100000:65536')]
      ct = without_residual_generations(Struct.new(:map_mode, :datasets, :uid_map, :gid_map) do
        def running?
          false
        end

        def manipulate(_holder, block:, &)
          yield
        end
      end.new('native', [ds1, ds2], uid_map, gid_map))
      command = described_class.new({ map_mode: 'zfs' }, {})
      allow(command).to receive(:progress)
      expect(command).to receive(:zfs).ordered.with(:unmount, nil, ds2, valid_rcs: [1])
      expect(command).to receive(:zfs).ordered.with(:unmount, nil, ds1, valid_rcs: [1])
      expect(command).to receive(:zfs).ordered.with(
        :set,
        'uidmap="0:100000:65536" gidmap="0:100000:65536"',
        ds1
      )
      expect(command).to receive(:zfs).ordered.with(:mount, nil, ds1)
      expect(command).to receive(:zfs).ordered.with(
        :set,
        'uidmap="0:100000:65536" gidmap="0:100000:65536"',
        ds2
      )
      expect(command).to receive(:zfs).ordered.with(:mount, nil, ds2)

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.map_mode).to eq('zfs')
    end

    it 'blocks map-mode changes while an active run is finalizing' do
      ct = with_runtime_generation(
        Struct.new(:map_mode) do
          def running?
            false
          end

          def manipulate(_holder, block:, &)
            yield
          end
        end.new('native'),
        role: 'active'
      )

      expect do
        described_class.new({ map_mode: 'zfs' }, {}).execute(ct)
      end.to raise_error(
        OsCtld::CommandFailed,
        /container map-mode change is blocked.*active/
      )
    end
  end

  describe OsCtld::Commands::Container::Chown do
    let(:usernet_class) { stub_const('OsCtld::Commands::User::LxcUsernet', Class.new) }

    before do
      stub_db
    end

    class FakeUser
      attr_reader :name, :ugid, :uid_map, :gid_map

      def initialize(name:, ugid:, uid_map:, gid_map:)
        @name = name
        @ugid = ugid
        @uid_map = uid_map
        @gid_map = gid_map
      end
    end

    class FakeCtForChown
      attr_reader :pool, :group, :log_path, :datasets
      attr_accessor :user, :state

      def initialize(pool:, group:, user:, log_path:, datasets:)
        @pool = pool
        @group = group
        @user = user
        @log_path = log_path
        @datasets = datasets
        @state = :stopped
      end

      def map_mode
        'zfs'
      end

      def uid_map
        user.uid_map
      end

      def gid_map
        user.gid_map
      end

      def lxc_dir(user: @user)
        "/lxc/#{user.name}/ct1"
      end

      def chown(new_user)
        @user = new_user
      end

      def manipulate(_holder, block:, &)
        yield
      end
    end

    it 'enforces the stopped-state precondition' do
      pool = build_pool
      user = FakeUser.new(name: 'alice', ugid: 1000, uid_map: [], gid_map: [])
      ct = without_residual_generations(FakeCtForChown.new(
                                          pool:,
                                          group: double,
                                          user:,
                                          log_path: '/tmp/ct.log',
                                          datasets: []
                                        ))
      ct.state = :running
      allow(OsCtld::DB::Users).to receive(:find).with('bob', pool).and_return(
        FakeUser.new(name: 'bob', ugid: 1001, uid_map: [], gid_map: [])
      )

      expect { described_class.new({ user: 'bob' }, {}).execute(ct) }
        .to raise_error(OsCtld::CommandFailed, 'container has to be stopped first')
    end

    it 'moves the container, remaps zfs datasets, and regenerates lxc-usernet' do
      with_tmpdir do |tmpdir|
        monitor = stub_const('OsCtld::Monitor::Master', Class.new do
          def self.demonitor(*); end

          def self.monitor(*); end
        end)
        old_user = lockable(FakeUser.new(
                              name: 'alice',
                              ugid: 1000,
                              uid_map: [double(to_s: '0:100000:65536')],
                              gid_map: [double(to_s: '0:100000:65536')]
                            ))
        new_user = lockable(FakeUser.new(
                              name: 'bob',
                              ugid: 1001,
                              uid_map: [double(to_s: '0:200000:65536')],
                              gid_map: [double(to_s: '0:200000:65536')]
                            ))
        group = Struct.new(:new_path, :old_path) do
          def setup_for?(_user)
            false
          end

          def userdir(user)
            user.name == 'bob' ? new_path : old_path
          end

          def has_containers?(_user)
            false
          end
        end.new(File.join(tmpdir, 'new-user'), File.join(tmpdir, 'old-user'))
        log_path = File.join(tmpdir, 'ct.log')
        File.write(log_path, 'log')
        ds1 = Struct.new(:relative_name).new('rootfs')
        ds2 = Struct.new(:relative_name).new('data')
        ct = without_residual_generations(lockable(FakeCtForChown.new(
                                                     pool: build_pool,
                                                     group:,
                                                     user: old_user,
                                                     log_path:,
                                                     datasets: [ds1, ds2]
                                                   )))
        allow(OsCtld::DB::Users).to receive(:find).with('bob', ct.pool).and_return(new_user)
        allow(monitor).to receive(:demonitor)
        allow(monitor).to receive(:monitor)
        allow(FileUtils).to receive(:mkdir_p)
        allow(File).to receive(:chown)
        allow(Dir).to receive(:rmdir)
        command = described_class.new({ user: 'bob' }, {})
        allow(command).to receive(:syscmd).with('mv /lxc/alice/ct1 /lxc/bob/ct1')
        allow(command).to receive(:zfs)
        allow(command).to receive(:call_cmd).with(usernet_class).and_return(status: true, output: nil)

        expect(command.execute(ct)).to eq(status: true, output: nil)
        expect(monitor).to have_received(:demonitor).with(ct)
        expect(monitor).to have_received(:monitor).with(ct)
        expect(command).to have_received(:zfs).with(:set, /0:200000:65536/, ds1)
        expect(command).to have_received(:zfs).with(:set, /0:200000:65536/, ds2)
        expect(ct.user).to equal(new_user)
      end
    end
  end

  describe OsCtld::Commands::Container::Chgrp do
    it 'moves the container into the new group and forwards missing_devices' do
      stub_db
      monitor = stub_const('OsCtld::Monitor::Master', Class.new do
        def self.demonitor(*); end

        def self.monitor(*); end
      end)
      pool = build_pool
      user = Struct.new(:ugid).new(1000)
      old_group = lockable(Struct.new(:old_path, :name, :pool) do
        def setup_for?(_user)
          true
        end

        def userdir(_user)
          old_path
        end

        def has_containers?(_user)
          false
        end

        def groups_in_path
          [self]
        end
      end.new('/lxc/old', '/old', pool))
      new_group = lockable(Struct.new(:new_path, :name, :pool) do
        def setup_for?(_user)
          false
        end

        def userdir(_user)
          new_path
        end

        def inherited_cgroup_policy_state
          nil
        end

        def groups_in_path
          [self]
        end
      end.new('/lxc/new', '/new', pool))
      devices = Struct.new do
        def check_all_available!(*, **); end
      end.new
      ct = without_residual_generations(lockable(Struct.new(:pool, :user, :group, :devices) do
        attr_accessor :state

        def lxc_dir(group: self.group)
          group.name == '/new' ? '/lxc/new/ct1' : '/lxc/old/ct1'
        end

        def chgrp(new_group, missing_devices:)
          @group = new_group
          @missing_devices = missing_devices
        end

        attr_reader :missing_devices

        def manipulate(_holder, block:, &)
          yield
        end
      end.new(pool, user, old_group, devices)))
      ct.state = :stopped
      allow(OsCtld::DB::Groups).to receive(:find).with('/new', pool).and_return(new_group)
      allow(monitor).to receive(:demonitor)
      allow(monitor).to receive(:monitor)
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:chown)
      allow(Dir).to receive(:rmdir)
      command = described_class.new({ group: '/new', missing_devices: 'remove' }, {})
      allow(command).to receive(:syscmd).with('mv /lxc/old/ct1 /lxc/new/ct1')

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(monitor).to have_received(:demonitor).with(ct)
      expect(monitor).to have_received(:monitor).with(ct)
      expect(ct.missing_devices).to eq('remove')
    end
  end
end

# rubocop:enable Lint/ConstantDefinitionInBlock, Lint/UnusedBlockArgument, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/LeakyConstantDeclaration, RSpec/MessageSpies, RSpec/VerifiedDoubles
