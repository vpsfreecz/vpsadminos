# frozen_string_literal: true

# rubocop:disable Lint/UnusedBlockArgument, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/VerifiedDoubles

require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/utils/assets'

module OsCtld
  module Commands
    module Pool; end
    module User; end
  end
end

require 'osctld/commands/user/assets'
require 'osctld/commands/user/create'
require 'osctld/commands/user/idmap_list'
require 'osctld/commands/user/list'
require 'osctld/commands/user/show'
require 'osctld/commands/user/set'
require 'osctld/commands/user/unset'
require 'osctld/commands/user/setup'
require 'osctld/commands/user/register'
require 'osctld/commands/user/unregister'
require 'osctld/commands/user/lxc_usernet'
require 'osctld/commands/user/subugids'
require 'osctld/commands/pool/assets'
require 'osctld/commands/pool/list'
require 'osctld/commands/pool/show'
require 'osctld/commands/pool/set'
require 'osctld/commands/pool/unset'
require 'osctld/commands/pool/abort_export'
require 'osctld/commands/pool/auto_start_cancel'
require 'osctld/commands/pool/auto_start_queue'
require 'osctld/commands/pool/auto_start_trigger'
require 'osctld/commands/pool/install'
require 'osctld/commands/pool/uninstall'

RSpec.describe 'pool and user command adapters' do
  def stub_history
    stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
  end

  def stub_dbs
    stub_const('OsCtld::DB::Users', Class.new do
      def self.find(_name, _pool); end

      def self.contains?(_name, _pool); end

      def self.each_by_ids(_names, _pool); end

      def self.each; end

      def self.get; end

      def self.add(_user); end

      def self.sync(&block)
        block.call
      end
    end)
    stub_const('OsCtld::DB::Pools', Class.new do
      def self.find(_name); end

      def self.get; end

      def self.get_or_default(_name); end

      def self.contains?(_name); end
    end)
    stub_const('OsCtld::DB::Containers', Class.new do
      def self.get; end

      def self.each; end
    end)
    stub_const('OsCtld::DB::Groups', Class.new do
      def self.get; end
    end)
  end

  before do
    allow(stub_history).to receive(:log)
    allow(OsCtl::Lib::Logger).to receive(:log)
    stub_dbs
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

  describe 'user commands' do
    def build_user(registered: true)
      pool = Struct.new(:name).new('tank')
      attrs = Struct.new(:value) do
        def export
          value
        end
      end.new({ color: 'blue' })
      Struct.new(:pool, :name, :sysusername, :sysgroupname, :ugid, :homedir, :standalone, :attrs) do
        attr_accessor :registered, :changes

        def registered?
          registered
        end

        def id_range_allocation_owner
          "user:#{name}"
        end

        def ident
          "#{pool.name}:#{name}"
        end

        def uid_map
          [Struct.new(:ns_id, :host_id, :id_count) do
            def to_h
              { ns_id:, host_id:, id_count: }
            end
          end.new(0, 100_000, 65_536)]
        end

        def gid_map
          [Struct.new(:ns_id, :host_id, :id_count) do
            def to_h
              { ns_id:, host_id:, id_count: }
            end
          end.new(0, 100_000, 65_536)]
        end

        def set(changes)
          self.changes = changes
        end

        def unset(changes)
          self.changes = changes
        end

        def manipulate(_holder, block:, &)
          yield
        end

        def assets
          [{ path: '/tmp/user' }]
        end
      end.new(pool, 'alice', 'alice', 'alice', 1000, '/home/alice', false, attrs).tap do |u|
        u.registered = registered
        u.changes = nil
      end
    end

    it 'exports user assets through the asset validator' do
      user = build_user
      allow(OsCtld::DB::Users).to receive(:find).with('alice', 'tank').and_return(user)
      command = OsCtld::Commands::User::Assets.new({ name: 'alice', pool: 'tank' }, {})
      allow(command).to receive(:list_and_validate_assets).with(user).and_return([{ path: '/tmp/user' }])

      expect(command.execute).to eq(status: true, output: [{ path: '/tmp/user' }])
    end

    it 'lists and shows users with exported attrs and registration filters' do
      registered = build_user(registered: true)
      unregistered = build_user(registered: false)
      allow(OsCtld::DB::Users).to receive(:each_by_ids).with(['alice'], 'tank').and_yield(registered).and_yield(unregistered)
      allow(OsCtld::DB::Users).to receive(:find).with('alice', 'tank').and_return(registered)

      expect(OsCtld::Commands::User::List.run(names: ['alice'], pool: 'tank', registered: true)).to eq(
        status: true,
        output: [
          {
            pool: 'tank',
            name: 'alice',
            username: 'alice',
            groupname: 'alice',
            ugid: 1000,
            homedir: '/home/alice',
            registered: true,
            standalone: false,
            uid_map: [{ ns_id: 0, host_id: 100_000, id_count: 65_536 }],
            gid_map: [{ ns_id: 0, host_id: 100_000, id_count: 65_536 }],
            color: 'blue'
          }
        ]
      )
      expect(OsCtld::Commands::User::Show.run(name: 'alice', pool: 'tank')).to eq(
        status: true,
        output: {
          pool: 'tank',
          name: 'alice',
          username: 'alice',
          groupname: 'alice',
          ugid: 1000,
          homedir: '/home/alice',
          registered: true,
          standalone: false,
          uid_map: [{ ns_id: 0, host_id: 100_000, id_count: 65_536 }],
          gid_map: [{ ns_id: 0, host_id: 100_000, id_count: 65_536 }],
          color: 'blue'
        }
      )
    end

    it 'exports uid and gid mappings as flat rows' do
      user = build_user
      allow(OsCtld::DB::Users).to receive(:find).with('alice', 'tank').and_return(user)

      expect(OsCtld::Commands::User::IdMapList.run(name: 'alice', pool: 'tank', uid: true, gid: true)).to eq(
        status: true,
        output: [
          { type: :uid, ns_id: 0, host_id: 100_000, count: 65_536 },
          { type: :gid, ns_id: 0, host_id: 100_000, count: 65_536 }
        ]
      )
    end

    it 'filters supported set and unset changes' do
      user = build_user
      command_set = OsCtld::Commands::User::Set.new({ standalone: true, attrs: { color: 'red' }, ignored: true }, {})
      command_unset = OsCtld::Commands::User::Unset.new({ standalone: true, ignored: true }, {})

      expect(command_set.execute(user)).to eq(status: true, output: nil)
      expect(user.changes).to eq(standalone: true, attrs: { color: 'red' })
      expect(command_unset.execute(user)).to eq(status: true, output: nil)
      expect(user.changes).to eq(standalone: true)
    end

    it 'sets up user directories, registers the user, and starts the supervisor' do
      with_tmpdir do |tmpdir|
        supervisor = stub_const('OsCtld::UserControl::Supervisor', Class.new do
          def self.start_server(_u); end
        end)
        user = lockable(
          Struct.new(:userdir, :homedir, :ugid) do
            def manipulate(_holder, block:, &)
              yield
            end
          end.new(File.join(tmpdir, 'userdir'), File.join(tmpdir, 'home'), 1000)
        )
        allow(supervisor).to receive(:start_server)
        allow(OsCtld::DB::Users).to receive(:add).with(user)
        allow(File).to receive(:chown)

        expect(OsCtld::Commands::User::Setup.run(user: user)).to eq(status: true, output: nil)
        expect(OsCtld::DB::Users).to have_received(:add).with(user)
        expect(supervisor).to have_received(:start_server).with(user)
      end
    end

    it 'rejects custom mappings when id_range is given without block_index' do
      pool = Struct.new(:name).new('tank')
      stub_const('OsCtld::IdMap', Class.new do
        def self.from_string_list(_list); end
      end)
      stub_const('OsCtld::User', Class.new do
        attr_reader :pool, :name

        def initialize(pool, name, load: false)
          @pool = pool
          @name = name
        end

        def id_range_allocation_owner
          "user:#{name}"
        end

        def manipulate(_holder, block:, &)
          yield
        end

        def configure(*); end
      end)
      allow(OsCtld::DB::Pools).to receive(:get_or_default).with('tank').and_return(pool)
      allow(OsCtld::DB::Users).to receive(:contains?).with('alice', pool).and_return(false)
      allow(OsCtld::IdMap).to receive(:from_string_list).and_return(double(valid?: true))

      expect do
        OsCtld::Commands::User::Create.run(
          name: 'alice',
          pool: 'tank',
          id_range: 'custom',
          uid_map: ['0:100000:65536'],
          gid_map: ['0:100000:65536']
        )
      end.to raise_error(OsCtld::CommandFailed, 'unsupported flag combination')
    end

    it 'allocates default mappings and runs setup, register, and subugid regeneration' do
      pool = Struct.new(:name).new('tank')
      range = Struct.new(:name) do
        def allocate(_count, owner:)
          { block_index: 7, first_id: 100_000, id_count: 65_536 }
        end
      end.new('default')
      uid_map = double('uid_map', valid?: true)
      gid_map = double('gid_map', valid?: true)
      user_class = stub_const('OsCtld::User', Class.new do
        attr_reader :pool, :name, :configured

        def initialize(pool, name, load: false)
          @pool = pool
          @name = name
        end

        def id_range_allocation_owner
          "user:#{name}"
        end

        def manipulate(_holder, block:, &)
          yield
        end

        def configure(uid_map, gid_map, ugid:, standalone:)
          @configured = { uid_map:, gid_map:, ugid:, standalone: }
        end
      end)
      id_ranges = stub_const('OsCtld::DB::IdRanges', Class.new do
        def self.find(_name, _pool); end
      end)
      id_map = stub_const('OsCtld::IdMap', Class.new do
        def self.from_string_list(_list); end
      end)
      allow(OsCtld::DB::Pools).to receive(:get_or_default).with('tank').and_return(pool)
      allow(OsCtld::DB::Users).to receive(:contains?).with('alice', pool).and_return(false)
      allow(id_ranges).to receive(:find).with('default', 'tank').and_return(range)
      allow(id_map).to receive(:from_string_list).with(['0:100000:65536']).and_return(uid_map, gid_map)

      command = OsCtld::Commands::User::Create.new(
        { name: 'alice', pool: 'tank', ugid: 1234, standalone: false },
        {}
      )
      allow(command).to receive(:progress)
      allow(command).to receive(:call_cmd!).with(
        OsCtld::Commands::User::Setup,
        user: instance_of(user_class)
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        OsCtld::Commands::User::Register,
        name: 'alice',
        pool: 'tank'
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        OsCtld::Commands::User::SubUGIds
      ).and_return(status: true, output: nil)

      expect(command.base_execute).to eq(status: true, output: nil)
      expect(command).to have_received(:progress).with('Allocated block #7 from ID range default')
    end

    it 'registers and unregisters a specific user through SystemUsers' do
      system_users = stub_const('OsCtld::SystemUsers', Class.new do
        def self.add(*); end

        def self.remove(*); end
      end)
      user = lockable(build_user(registered: false))
      allow(OsCtld::DB::Users).to receive(:find).with('alice', 'tank').and_return(user)
      allow(system_users).to receive(:add)
      allow(system_users).to receive(:remove)

      expect(OsCtld::Commands::User::Register.run(name: 'alice', pool: 'tank')).to eq(status: true, output: nil)
      expect(user.registered?).to be(true)
      expect(OsCtld::Commands::User::Unregister.run(name: 'alice', pool: 'tank')).to eq(status: true, output: nil)
      expect(user.registered?).to be(false)
    end

    it 'generates lxc-usernet entries for bridged interfaces' do
      with_tmpdir do |tmpdir|
        stub_const('OsCtld::Commands::User::LxcUsernet::LXC_USERNET', File.join(tmpdir, 'lxc-usernet'))
        user = build_user
        netif1 = Struct.new(:type, :link).new(:bridge, 'br0')
        netif2 = Struct.new(:type, :link).new(:routed, nil)
        ct = Struct.new(:user, :netifs).new(user, [netif1, netif2])
        allow(OsCtld::DB::Users).to receive(:each).and_yield(user)
        allow(OsCtld::DB::Containers).to receive(:each).and_yield(ct)

        expect(OsCtld::Commands::User::LxcUsernet.run).to eq(status: true, output: nil)
        expect(File.read(File.join(tmpdir, 'lxc-usernet')).lines.map(&:chomp)).to eq(
          [
            'alice veth none 4',
            'alice veth br0 4'
          ]
        )
      end
    end
  end

  describe 'pool commands' do
    def build_pool(imported: true, name: 'tank')
      attrs = Struct.new(:value) do
        def export
          value
        end
      end.new({ color: 'blue' })
      autostart_plan = Struct.new(:queue) do
        def clear; end
      end.new([Struct.new(:id, :priority).new(1, 10)])
      Struct.new(:name, :dataset, :state, :parallel_start, :parallel_stop, :attrs, :autostart_plan) do
        def imported?
          @imported
        end

        attr_writer :imported

        def abort_export; end

        def assets
          [{ path: '/tmp/pool' }]
        end

        def autostart(force: false, hook_timeout: nil); end

        def inclusively(&block)
          block.call
        end

        def manipulate(_holder, block:, &)
          yield
        end

        def set(changes)
          @changes = changes
        end

        def unset(changes)
          @unset = changes
        end

        attr_reader :changes

        def unset_changes
          @unset
        end
      end.new(name, "#{name}/data", :active, 2, 4, attrs, autostart_plan).tap do |pool|
        pool.imported = imported
      end
    end

    it 'exports pool assets through the asset validator' do
      pool = build_pool
      allow(OsCtld::DB::Pools).to receive(:find).with('tank').and_return(pool)
      command = OsCtld::Commands::Pool::Assets.new({ name: 'tank' }, {})
      allow(command).to receive(:list_and_validate_assets).with(pool).and_return([{ path: '/tmp/pool' }])

      expect(command.execute).to eq(status: true, output: [{ path: '/tmp/pool' }])
    end

    it 'lists and shows pools with aggregated counts and attrs' do
      pool = build_pool
      pool2 = build_pool(name: 'other')
      allow(OsCtld::DB::Pools).to receive(:get).and_return([pool, pool2])
      allow(OsCtld::DB::Pools).to receive(:find).with('tank').and_return(pool)
      allow(OsCtld::DB::Users).to receive(:get).and_return([Struct.new(:pool).new(pool)])
      allow(OsCtld::DB::Groups).to receive(:get).and_return([Struct.new(:pool).new(pool)])
      allow(OsCtld::DB::Containers).to receive(:get).and_return([Struct.new(:pool).new(pool)])

      expect(OsCtld::Commands::Pool::List.run(names: ['tank'])).to eq(
        status: true,
        output: [
          {
            name: 'tank',
            dataset: 'tank/data',
            state: :active,
            users: 1,
            groups: 1,
            containers: 1,
            parallel_start: 2,
            parallel_stop: 4,
            color: 'blue'
          }
        ]
      )
      expect(OsCtld::Commands::Pool::Show.run(name: 'tank')).to eq(
        status: true,
        output: {
          name: 'tank',
          dataset: 'tank/data',
          state: :active,
          users: 1,
          groups: 1,
          containers: 1,
          parallel_start: 2,
          parallel_stop: 4,
          color: 'blue'
        }
      )
    end

    it 'filters supported set and unset changes and validates parallel counts' do
      pool = build_pool
      expect { OsCtld::Commands::Pool::Set.new({ parallel_start: 0 }, {}).execute(pool) }
        .to raise_error(OsCtld::CommandFailed, 'parallel_start has to be greater than 0')

      command_set = OsCtld::Commands::Pool::Set.new({ parallel_start: '3', attrs: { color: 'red' }, ignored: true }, {})
      command_unset = OsCtld::Commands::Pool::Unset.new({ options: %w[parallel_start], attrs: true }, {})

      expect(command_set.execute(pool)).to eq(status: true, output: nil)
      expect(pool.changes).to eq(parallel_start: 3, attrs: { color: 'red' })
      expect(command_unset.execute(pool)).to eq(status: true, output: nil)
      expect(pool.unset_changes).to eq(options: [:parallel_start], attrs: true)
    end

    it 'aborts exports, clears autostart queues, and lists queue entries only for imported pools' do
      imported = build_pool(imported: true)
      unimported = build_pool(imported: false)
      allow(OsCtld::DB::Pools).to receive(:find).with('tank').and_return(imported)
      allow(OsCtld::DB::Pools).to receive(:find).with('other').and_return(unimported)
      allow(imported).to receive(:abort_export)
      allow(imported.autostart_plan).to receive(:clear)

      expect(OsCtld::Commands::Pool::AbortExport.run(name: 'tank')).to eq(status: true, output: nil)
      expect(OsCtld::Commands::Pool::AutoStartCancel.run(name: 'tank')).to eq(status: true, output: nil)
      expect(OsCtld::Commands::Pool::AutoStartQueue.run(name: 'tank')).to eq(
        status: true,
        output: [{ id: 1, priority: 10 }]
      )
      expect(OsCtld::Commands::Pool::AutoStartQueue.run(name: 'other')).to eq(
        status: true,
        output: []
      )
    end

    it 'maps autostart hook failures to command errors' do
      stub_daemon
      pool = build_pool
      allow(OsCtld::DB::Pools).to receive(:find).with('tank').and_return(pool)
      allow(pool).to receive(:autostart).and_raise(
        OsCtld::HookFailed.new(Class.new { def self.hook_name = 'pre_autostart' }.new, '/hooks/pre-autostart', 1)
      )

      expect { OsCtld::Commands::Pool::AutoStartTrigger.run(name: 'tank') }
        .to raise_error(
          OsCtld::CommandFailed,
          'pre-autostart hook failed: hook pre_autostart at /hooks/pre-autostart exited with 1'
        )
    end

    it 'holds a lifecycle task around the complete autostart trigger' do
      pool = build_pool
      task_active = false
      daemon = instance_double(
        Class.new do
          def config; end

          def with_lifecycle_task(**); end
        end,
        config: Struct.new(:restart).new(
          Struct.new(:hook_timeout).new(30)
        )
      )
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon_class).to receive(:get).and_return(daemon)
      allow(OsCtld::DB::Pools).to receive(:find).with('tank').and_return(pool)
      allow(daemon).to receive(:with_lifecycle_task) do |**, &block|
        task_active = true
        block.call
      ensure
        task_active = false
      end
      allow(pool).to receive(:autostart) do |force:, hook_timeout:|
        expect(task_active).to be(true)
        expect(force).to be(true)
        expect(hook_timeout).to eq(30)
      end

      expect(OsCtld::Commands::Pool::AutoStartTrigger.run(name: 'tank')).to eq(
        status: true,
        output: nil
      )
      expect(daemon).to have_received(:with_lifecycle_task).with(
        kind: :pool_autostart_trigger,
        details: { pool: 'tank' }
      )
    end

    it 'does not begin an autostart trigger after drain closes admission' do
      pool = build_pool
      daemon = instance_double(
        Class.new do
          def with_lifecycle_task(**); end
        end
      )
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon_class).to receive(:get).and_return(daemon)
      allow(OsCtld::DB::Pools).to receive(:find).with('tank').and_return(pool)
      allow(daemon).to receive(:with_lifecycle_task)
        .and_raise(OsCtld::CommandFailed, 'lifecycle admission is closed')
      allow(pool).to receive(:autostart)

      expect do
        OsCtld::Commands::Pool::AutoStartTrigger.run(name: 'tank')
      end.to raise_error(
        OsCtld::CommandFailed,
        'lifecycle admission is closed'
      )
      expect(pool).not_to have_received(:autostart)
    end

    it 'validates pool dataset prefixes and delegates install/import and uninstall/zfs cleanup' do
      import_class = stub_const('OsCtld::Commands::Pool::Import', Class.new)
      pool_class = stub_const('OsCtld::Pool', Class.new)
      pool_class.const_set(:PROPERTY_ACTIVE, 'org.vpsadminos.active')
      pool_class.const_set(:PROPERTY_DATASET, 'org.vpsadminos.dataset')
      osup = stub_const('OsUp', Class.new do
        def self.init(*); end
      end)
      allow(osup).to receive(:init)
      allow(OsCtld::DB::Pools).to receive(:contains?).with('tank').and_return(false)
      install = OsCtld::Commands::Pool::Install.new({ name: 'tank', dataset: 'tank/data' }, {})
      allow(install).to receive(:zfs).with(:set, 'org.vpsadminos.active=yes org.vpsadminos.dataset="tank/data"', 'tank')
      allow(install).to receive(:call_cmd!).with(import_class, name: 'tank').and_return(status: true, output: nil)

      expect(install.execute).to eq(status: true, output: nil)

      uninstall = OsCtld::Commands::Pool::Uninstall.new({ name: 'tank' }, {})
      allow(OsCtld::DB::Pools).to receive(:contains?).with('tank').and_return(false)
      allow(uninstall).to receive(:zfs).with(:set, 'org.vpsadminos.active=no', 'tank')
      allow(uninstall).to receive(:zfs).with(:inherit, 'org.vpsadminos.active', 'tank')
      allow(uninstall).to receive(:zfs).with(:inherit, 'org.vpsadminos.dataset', 'tank')

      expect(uninstall.execute).to eq(status: true, output: nil)
    end
  end
end

# rubocop:enable Lint/UnusedBlockArgument, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/VerifiedDoubles
