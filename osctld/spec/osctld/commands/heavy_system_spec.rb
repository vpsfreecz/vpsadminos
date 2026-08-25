# frozen_string_literal: true

# rubocop:disable Lint/UnusedBlockArgument, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/VerifiedDoubles

require 'stringio'
require 'osctld/exceptions'
require 'osctld/command'

module OsCtld
  module Commands
    module Self; end
    module Pool; end
    module User; end
  end
end

require 'osctld/commands/self/shutdown'
require 'osctld/commands/pool/import'
require 'osctld/commands/pool/export'
require 'osctld/commands/user/delete'
require 'osctld/commands/user/subugids'

RSpec.describe 'heavy system commands' do
  def lockable(obj, event_log: nil, lock_event: nil)
    obj.define_singleton_method(:manipulated_by) { @manipulated_by }
    obj.define_singleton_method(:acquire_manipulation_lock) do |holder, block: false|
      event_log << lock_event if event_log
      @manipulated_by = holder
      true
    end
    obj.define_singleton_method(:release_manipulation_lock) do
      @manipulated_by = nil
    end
    obj
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  describe OsCtld::Commands::Self::Shutdown do
    let(:daemon) { double('Daemon', begin_shutdown: nil, abort_shutdown?: false, confirm_shutdown: nil) }

    before do
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon_class).to receive(:get).and_return(daemon)
      pool_export = stub_const('OsCtld::Commands::Pool::Export', Class.new do
        def self.run(**); end
      end)
      allow(pool_export).to receive(:run).and_return(status: true, output: nil)
    end

    it 'grabs pools and containers, autostops multiple pools, and exports them with the wall message' do
      tracker_class = stub_const('OsCtld::ProgressTracker', Class.new)
      allow(tracker_class).to receive(:new).and_return(double('Tracker'))
      event_log = []
      pool1 = lockable(
        Struct.new(:name, :event_log) do
          attr_reader :disabled, :begin_stop_calls, :autostop_calls, :wait_calls

          def initialize(*)
            super
            @disabled = false
            @begin_stop_calls = 0
            @autostop_calls = []
            @wait_calls = 0
          end

          def exclusively
            yield
          end

          def disable
            @disabled = true
          end

          def begin_stop
            event_log << :pool1_begin_stop
            @begin_stop_calls += 1
          end

          def autostop_no_wait(**opts)
            @autostop_calls << opts
          end

          def wait_for_autostop
            @wait_calls += 1
          end
        end.new('tank', event_log)
      )
      pool2 = lockable(
        Struct.new(:name, :event_log) do
          attr_reader :disabled, :begin_stop_calls, :autostop_calls, :wait_calls

          def initialize(*)
            super
            @disabled = false
            @begin_stop_calls = 0
            @autostop_calls = []
            @wait_calls = 0
          end

          def exclusively
            yield
          end

          def disable
            @disabled = true
          end

          def begin_stop
            event_log << :pool2_begin_stop
            @begin_stop_calls += 1
          end

          def autostop_no_wait(**opts)
            @autostop_calls << opts
          end

          def wait_for_autostop
            @wait_calls += 1
          end
        end.new('pool2', event_log)
      )
      ct1 = lockable(
        Struct.new(:pool).new(pool1),
        event_log:,
        lock_event: :ct1_lock
      )
      ct2 = lockable(
        Struct.new(:pool).new(pool2),
        event_log:,
        lock_event: :ct2_lock
      )
      db_pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.get; end
      end)
      db_cts = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(db_pools).to receive(:get) { [pool1, pool2] }
      allow(db_cts).to receive(:get) { [ct1, ct2] }

      expect(
        described_class.run(wall: true, message: 'Shutting down')
      ).to eq(status: true, output: nil)
      expect(daemon).to have_received(:begin_shutdown)
      expect(daemon).to have_received(:confirm_shutdown)
      expect(pool1.begin_stop_calls).to eq(1)
      expect(pool2.begin_stop_calls).to eq(1)
      expect(event_log).to eq(
        %i[pool1_begin_stop pool2_begin_stop ct1_lock ct2_lock]
      )
      expect(pool1.autostop_calls.first[:message]).to eq('Shutting down')
      expect(pool2.autostop_calls.first[:message]).to eq('Shutting down')
      expect(OsCtld::Commands::Pool::Export).to have_received(:run).with(
        internal: { handler: nil, indirect: true },
        name: 'tank',
        force: true,
        grab_containers: false,
        stop_containers: true,
        unregister_users: false,
        message: 'Shutting down'
      )
      expect(OsCtld::Commands::Pool::Export).to have_received(:run).with(
        internal: { handler: nil, indirect: true },
        name: 'pool2',
        force: true,
        grab_containers: false,
        stop_containers: true,
        unregister_users: false,
        message: 'Shutting down'
      )
    end

    it 'releases already grabbed pools when shutdown is aborted early' do
      pool = lockable(Struct.new(:name) do
        def exclusively
          yield
        end
      end.new('tank'))
      db_pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.get; end
      end)
      db_cts = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(db_pools).to receive(:get).and_return([pool])
      allow(db_cts).to receive(:get).and_return([])
      allow(daemon).to receive(:abort_shutdown?).and_return(false, true)

      expect { described_class.run }
        .to raise_error(OsCtld::CommandFailed, 'shutdown aborted')
      expect(pool.manipulated_by).to be_nil
    end
  end

  describe OsCtld::Commands::Pool::Import do
    before do
      stub_const('OsCtld::Pool', Class.new do
        attr_reader :name, :dataset

        def initialize(name, dataset)
          @name = name
          @dataset = dataset
        end

        def manipulate(_holder, block:, &)
          yield
        end

        def init; end
        def setup; end
        def disable; end
        def autostart; end
      end)
      stub_const('OsCtld::Pool::PROPERTY_ACTIVE', 'org.vpsadminos.active')
      stub_const('OsCtld::Pool::PROPERTY_DATASET', 'org.vpsadminos.dataset')
      hook = stub_const('OsCtld::Hook', Class.new do
        def self.run(*); end
      end)
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(hook).to receive(:run)
      daemon = double(shutdown?: false)
      allow(daemon).to receive(:with_lifecycle_task).and_yield
      allow(daemon_class).to receive(:get).and_return(daemon)
      db_pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.contains?(_name); end

        def self.sync(&block)
          block.call
        end

        def self.add(_pool); end

        def self.remove(_pool); end
      end)
      allow(db_pools).to receive(:contains?).and_return(false)
      allow(db_pools).to receive(:add)
      allow(db_pools).to receive(:remove)
    end

    it 'rejects importing a pool that is not mounted' do
      db_pools = OsCtld::DB::Pools
      allow(db_pools).to receive(:contains?).with('tank').and_return(false)
      command = described_class.new({ name: 'tank' }, {})
      allow(command).to receive(:zfs).with(
        :get,
        '-H -o value mounted,org.vpsadminos.dataset',
        'tank'
      ).and_return(double(output: "no -\n"))

      expect { command.execute }
        .to raise_error(OsCtld::CommandFailed, 'the pool is not mounted')
    end

    it 'removes the pool from the database when an upgrade fails during import' do
      command = described_class.new({}, {})
      allow(command).to receive(:upgrade).with('tank') do
        raise OsCtld::PoolUpgradeError.new('tank', StandardError.new('boom'))
      end

      expect { command.send(:do_import, 'tank', 'tank/data') }
        .to raise_error(OsCtld::PoolUpgradeError)
      expect(OsCtld::DB::Pools).to have_received(:remove).with(instance_of(OsCtld::Pool))
    end
  end

  describe OsCtld::Commands::Pool::Export do
    before do
      hook = stub_const('OsCtld::Hook', Class.new do
        def self.run(*); end
      end)
      allow(hook).to receive(:run)
      stub_const('OsCtld::User', Class.new do
        attr_accessor :pool, :name, :userdir, :id_range_allocation_owner

        def exclusively
          yield
        end
      end)
      stub_const('OsCtld::Container', Class.new do
        attr_accessor :pool, :ident, :config_state, :runtime_state

        def unregister; end
      end)
      stub_const('OsCtld::Repository', Class.new do
        attr_accessor :pool

        def stop; end
      end)
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon_class).to receive(:get).and_return(double(shutdown?: false, abort_shutdown?: false))
    end

    it 'returns ok with a progress note when the pool is missing and if_imported is set' do
      db_pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.find(_name); end
      end)
      allow(db_pools).to receive(:find).with('tank').and_return(nil)
      command = described_class.new({ name: 'tank', if_imported: true }, {})
      allow(command).to receive(:progress)

      expect(command.execute).to eq(status: true, output: nil)
      expect(command).to have_received(:progress).with('pool not imported')
    end

    it 'rejects exports of pools with running containers unless forced' do
      pool = double('Pool')
      db_pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.find(_name); end
      end)
      db_cts = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(db_pools).to receive(:find).with('tank').and_return(pool)
      allow(db_cts).to receive(:get).and_return([Struct.new(:pool) do
        def running?
          true
        end
      end.new(pool)])

      expect { described_class.run(name: 'tank') }
        .to raise_error(OsCtld::CommandFailed, 'the pool has running containers')
    end

    it 'unregisters entities, regenerates user files, removes the pool, and deploys send-receive keys' do
      user_unreg = stub_const('OsCtld::Commands::User::Unregister', Class.new)
      subugids = stub_const('OsCtld::Commands::User::SubUGIds', Class.new)
      usernet = stub_const('OsCtld::Commands::User::LxcUsernet', Class.new)
      monitor = stub_const('OsCtld::Monitor::Master', Class.new do
        def self.demonitor(*); end
      end)
      console = stub_const('OsCtld::Console', Class.new do
        def self.remove(*); end
      end)
      history = stub_const('OsCtld::History', Class.new do
        def self.close(*); end
      end)
      send_receive = stub_const('OsCtld::SendReceive', Class.new do
        def self.deploy; end
      end)
      bpf = stub_const('OsCtld::BpfFs', Class.new do
        def self.remove_pool(*); end
      end)
      cgroup = stub_const('OsCtld::CGroup', Class.new do
        def self.rmpath_all(*); end
      end)
      allow(monitor).to receive(:demonitor)
      allow(console).to receive(:remove)
      allow(history).to receive(:close)
      allow(send_receive).to receive(:deploy)
      allow(bpf).to receive(:remove_pool)
      allow(cgroup).to receive(:rmpath_all)

      pool = lockable(
        Struct.new(:name) do
          def manipulate(_holder, block:, &)
            yield
          end

          def begin_export; end
          def begin_stop; end

          def exclusively
            yield
          end

          def disable; end
          def autostop_and_wait(**); end
          def all_stop; end
          def abort_export? = false
        end.new('tank')
      )
      root_group = Struct.new(:pool, :cgroup_path).new(pool, '/sys/fs/cgroup/osctl/root')
      user_class = OsCtld::User
      container_class = OsCtld::Container
      repo_class = OsCtld::Repository
      user = lockable(user_class.new).tap do |u|
        u.pool = pool
        u.name = 'alice'
        u.userdir = '/home/alice'
        u.id_range_allocation_owner = 'user:alice'
      end
      ct = lockable(container_class.new).tap do |c|
        c.pool = pool
        c.ident = 'tank:ct1'
        c.config_state = :ready
        c.runtime_state = :stopped
      end
      repo = repo_class.new.tap do |r|
        r.pool = pool
      end
      id_range = Struct.new(:pool) do
        def free_by(_owner); end
      end.new(pool)
      db_pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.find(_name); end
        def self.remove(_pool); end
      end)
      db_cts = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
        def self.remove(_obj); end
      end)
      db_users = stub_const('OsCtld::DB::Users', Class.new do
        def self.get; end
        def self.remove(_obj); end
      end)
      db_groups = stub_const('OsCtld::DB::Groups', Class.new do
        def self.get; end
        def self.remove(_obj); end
        def self.root(_pool); end
      end)
      db_repos = stub_const('OsCtld::DB::Repositories', Class.new do
        def self.get; end
        def self.remove(_obj); end
      end)
      db_ranges = stub_const('OsCtld::DB::IdRanges', Class.new do
        def self.get; end
        def self.remove(_obj); end
      end)
      supervisor = stub_const('OsCtld::UserControl::Supervisor', Class.new do
        def self.stop_server(*); end
      end)
      allow(db_pools).to receive(:find).with('tank').and_return(pool)
      allow(db_cts).to receive(:get).and_return([ct])
      allow(db_users).to receive(:get).and_return([user])
      allow(db_groups).to receive(:get).and_return([root_group])
      allow(db_groups).to receive(:root).with(pool).and_return(root_group)
      allow(db_repos).to receive(:get).and_return([repo])
      allow(db_ranges).to receive(:get).and_return([id_range])
      allow(db_pools).to receive(:remove).with(pool)
      allow(supervisor).to receive(:stop_server).with(user)

      command = described_class.new(
        {
          name: 'tank',
          force: true,
          stop_containers: true,
          unregister_users: true
        },
        {}
      )
      allow(command).to receive(:call_cmd!).with(
        user_unreg,
        pool: 'tank',
        name: 'alice'
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(subugids).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(usernet).and_return(status: true, output: nil)
      allow(command).to receive(:syscmd)

      expect(command.execute).to eq(status: true, output: nil)
      expect(monitor).to have_received(:demonitor).with(ct)
      expect(console).to have_received(:remove).with(ct)
      expect(history).to have_received(:close).with(pool)
      expect(send_receive).to have_received(:deploy)
      expect(db_pools).to have_received(:remove).with(pool)
    end
  end

  describe OsCtld::Commands::User::Delete do
    before do
      stub_const('OsCtld::UserControl::Supervisor', Class.new do
        def self.stop_server(*); end
      end)
      stub_const('OsCtld::DB::IdRanges', Class.new do
        def self.get; end
      end)
      stub_const('OsCtld::DB::Users', Class.new do
        def self.remove(_user); end
      end)
      allow(OsCtld::UserControl::Supervisor).to receive(:stop_server)
      allow(OsCtld::DB::Users).to receive(:remove)
    end

    it 'rejects deleting users that still have containers' do
      user = Struct.new do
        def has_containers?
          true
        end
      end.new

      expect { described_class.new({}, {}).execute(user) }
        .to raise_error(OsCtld::CommandFailed, 'user has container(s)')
    end

    it 'unregisters the user, frees id ranges, removes the user, and regenerates subuids' do
      unregister = stub_const('OsCtld::Commands::User::Unregister', Class.new)
      subugids = stub_const('OsCtld::Commands::User::SubUGIds', Class.new)
      ranges = [Struct.new(:pool) do
        attr_reader :freed

        def free_by(owner)
          @freed = owner
        end
      end.new(Struct.new(:name).new('tank'))]
      allow(OsCtld::DB::IdRanges).to receive(:get).and_return(ranges)
      user = lockable(
        Struct.new(:name, :pool, :userdir, :config_path) do
          def has_containers?
            false
          end

          def id_range_allocation_owner
            'user:alice'
          end

          def manipulate(_holder, block:, &)
            yield
          end
        end.new('alice', ranges.first.pool, '/home/alice', '/home/alice.yml')
      )
      command = described_class.new({}, {})
      allow(command).to receive(:call_cmd!).with(
        unregister,
        name: 'alice',
        pool: 'tank'
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd).with(subugids).and_return(status: true, output: nil)
      allow(command).to receive(:syscmd)
      allow(File).to receive(:unlink).with('/home/alice.yml')

      expect(command.execute(user)).to eq(status: true, output: nil)
      expect(ranges.first.freed).to eq('user:alice')
      expect(OsCtld::DB::Users).to have_received(:remove).with(user)
    end
  end

  describe OsCtld::Commands::User::SubUGIds do
    it 'writes subuid and subgid files from the current user maps' do
      db_users = stub_const('OsCtld::DB::Users', Class.new do
        def self.get; end
      end)
      user = Struct.new(:ugid, :uid_map, :gid_map).new(
        1000,
        [Struct.new(:host_id, :id_count).new(100_000, 65_536)],
        [Struct.new(:host_id, :id_count).new(200_000, 65_536)]
      )
      allow(db_users).to receive(:get).and_yield([user])
      open_buffers = {}
      allow(File).to receive(:open) do |path, _mode, &block|
        io = StringIO.new
        open_buffers[path] = io
        block.call(io)
      end
      renames = []
      allow(File).to receive(:rename) do |src, dst|
        renames << [src, dst]
      end

      expect(described_class.run).to eq(status: true, output: nil)
      expect(open_buffers['/etc/subuid.new'].string).to eq("1000:100000:65536\n")
      expect(open_buffers['/etc/subgid.new'].string).to eq("1000:200000:65536\n")
      expect(renames).to eq(
        [
          ['/etc/subuid.new', '/etc/subuid'],
          ['/etc/subgid.new', '/etc/subgid']
        ]
      )
    end
  end
end

# rubocop:enable Lint/UnusedBlockArgument, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/VerifiedDoubles
