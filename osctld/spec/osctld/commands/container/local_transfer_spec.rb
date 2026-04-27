# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/VerifiedDoubles

require 'osctld/command'
require 'osctld/exceptions'

module OsCtld
  module Commands
    module Container; end
    module User; end
  end

  module DB; end
end

require 'osctld/commands/container/copy_cancel'
require 'osctld/commands/container/copy_cleanup'
require 'osctld/commands/container/copy_config'
require 'osctld/commands/container/copy_rootfs'
require 'osctld/commands/container/copy_state'
require 'osctld/commands/container/copy_sync'
require 'osctld/commands/container/move_cleanup'
require 'osctld/commands/container/move_config'
require 'osctld/commands/container/move_rootfs'
require 'osctld/commands/container/move_state'
require 'osctld/commands/container/move_sync'

module LocalTransferSpec
  Dataset = Struct.new(:name, :relative_name, :descendants) do
    def to_s
      name
    end
  end

  User = Struct.new(:name)
  Group = Struct.new(:name)

  Pool = Struct.new(:name, :ct_ds) do
    def ==(other)
      other.is_a?(Pool) && other.name == name
    end
  end

  FakeCt = Struct.new(
    :id, :pool, :state, :dataset, :user, :group, :send_log,
    :local_transfer_log, :save_config_calls, :closed_local_transfer_log,
    :cleanup_calls, keyword_init: true
  ) do
    def datasets
      [dataset] + dataset.descendants
    end

    def running?
      state == :running
    end

    def exclusively
      yield
    end

    def manipulate(_cmd, block:, &)
      yield
    end

    def acquire_manipulation_lock(_cmd, block: false)
      true
    end

    def release_manipulation_lock; end

    def transfer_in_progress?
      !!send_log || !!local_transfer_log
    end

    def open_local_transfer_log(role, opts)
      self.local_transfer_log = OsCtld::LocalTransfer::Log.new(role:, opts:)
      save_config
    end

    def close_local_transfer_log
      self.closed_local_transfer_log = true
      self.local_transfer_log = nil
      save_config
    end

    def save_config
      self.save_config_calls += 1
    end

    def dup(new_id, pool:, user:, group:, dataset:, network_interfaces:)
      FakeCt.new(
        id: new_id,
        pool: pool || self.pool,
        state: :staged,
        dataset: Dataset.new(dataset || File.join((pool || self.pool).ct_ds, new_id), '/', []),
        user: user || self.user,
        group: group || self.group,
        send_log: nil,
        local_transfer_log: nil,
        save_config_calls: 0,
        closed_local_transfer_log: false,
        cleanup_calls: []
      )
    end

    def new_run_conf
      self
    end

    def state=(v)
      self[:state] = v == :complete ? :stopped : v
    end
  end
end

RSpec.describe 'local container transfer commands' do
  def transfer_opts(operation: :copy, target_pool: 'tank', target_id: 'ct1-copy', datasets: nil)
    datasets ||= [
      OsCtld::LocalTransfer::Log::Dataset.new(
        relative_name: '/',
        source: 'tank/ct/ct1',
        target: "tank/ct/#{target_id}"
      )
    ]

    {
      operation:,
      target_pool:,
      target_id:,
      target_dataset: "tank/ct/#{target_id}",
      target_dataset_custom: false,
      target_user: 'alice',
      target_group: '/default',
      network_interfaces: true,
      datasets:
    }
  end

  def local_log(operation: :copy, state: :stage, snapshots: [], state_snapshot: nil, state_running: nil, datasets: nil)
    OsCtld::LocalTransfer::Log.new(
      role: :source,
      state:,
      snapshots: snapshots.dup,
      state_snapshot:,
      state_running:,
      opts: transfer_opts(operation:, datasets:)
    )
  end

  def source_ct(state: :stopped, log: nil, descendants: [])
    LocalTransferSpec::FakeCt.new(
      id: 'ct1',
      pool: LocalTransferSpec::Pool.new('tank', 'tank/ct'),
      state:,
      dataset: LocalTransferSpec::Dataset.new('tank/ct/ct1', '/', descendants),
      user: LocalTransferSpec::User.new('alice'),
      group: LocalTransferSpec::Group.new('/default'),
      send_log: nil,
      local_transfer_log: log,
      save_config_calls: 0,
      closed_local_transfer_log: false,
      cleanup_calls: []
    )
  end

  def target_ct(id: 'ct1-copy', state: :staged)
    LocalTransferSpec::FakeCt.new(
      id:,
      pool: LocalTransferSpec::Pool.new('tank', 'tank/ct'),
      state:,
      dataset: LocalTransferSpec::Dataset.new("tank/ct/#{id}", '/', []),
      user: LocalTransferSpec::User.new('alice'),
      group: LocalTransferSpec::Group.new('/default'),
      send_log: nil,
      local_transfer_log: nil,
      save_config_calls: 0,
      closed_local_transfer_log: false,
      cleanup_calls: []
    )
  end

  def stub_target_lookup(target)
    pools = stub_const('OsCtld::DB::Pools', Class.new do
      def self.find(_name); end
    end)
    containers = stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
      def self.contains?(_id, _pool); end
    end)

    allow(pools).to receive(:find).with('tank').and_return(target.pool)
    allow(containers).to receive(:find).with(target.id, target.pool).and_return(target)
    allow(containers).to receive(:contains?).and_return(false)

    [pools, containers]
  end

  def stub_daemon(writeout: false)
    config = Struct.new(:writeout) do
      def writeout_dirtied_pages?
        writeout
      end
    end.new(writeout)
    daemon = Struct.new(:config).new(config)

    stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
    stub_const('OsCtld::Commands::Container::Stop', Class.new)
    stub_const('OsCtld::Commands::Container::Start', Class.new)
    stub_const('OsCtld::Commands::Container::Delete', Class.new)
    stub_const('OsCtld::Commands::User::LxcUsernet', Class.new)
    stub_const('OsCtld::Container', Class.new) unless defined?(OsCtld::Container)
  end

  describe OsCtld::Commands::Container::CopyConfig do
    it 'creates a staged target and opens a copy transfer log' do
      source = source_ct(descendants: [LocalTransferSpec::Dataset.new('tank/ct/ct1/data', 'data', [])])
      target = target_ct
      _pools, containers = stub_target_lookup(target)
      users = stub_const('OsCtld::DB::Users', Class.new do
        def self.find(_name, _pool); end
      end)
      groups = stub_const('OsCtld::DB::Groups', Class.new do
        def self.find(_name, _pool); end
      end)
      builder = double(
        'Builder',
        valid?: true,
        errors: [],
        register: true,
        ctrc: double(dataset: target.dataset, map_mode: 'zfs'),
        setup_ct_dir: nil,
        setup_lxc_home: nil,
        setup_lxc_configs: nil,
        setup_log_file: nil,
        setup_user_hook_script_dir: nil,
        monitor: nil
      )
      builder_class = stub_const('OsCtld::Container::Builder', Class.new do
        def initialize(*, **); end
      end)
      created = []

      allow(containers).to receive(:find).with('ct1', 'tank').and_return(source)
      allow(users).to receive(:find)
      allow(groups).to receive(:find)
      allow(builder_class).to receive(:new).and_return(builder)
      allow(builder).to receive(:create_dataset) { |ds, **| created << ds.name }

      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          target_id: 'ct1-copy',
          network_interfaces: true
        },
        {}
      )
      allow(command).to receive(:call_cmd!).with(OsCtld::Commands::User::LxcUsernet).and_return(status: true, output: nil)

      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(source.local_transfer_log.opts.operation).to eq(:copy)
      expect(source.local_transfer_log.opts.datasets.map(&:source)).to eq(
        %w[tank/ct/ct1 tank/ct/ct1/data]
      )
      expect(created).to eq(%w[tank/ct/ct1-copy tank/ct/ct1-copy/data])
      expect(target.state).to eq(:staged)
    end

    it 'refuses to start when a send transfer is in progress' do
      source = source_ct
      source.send_log = double('SendLog')
      target = target_ct
      _pools, containers = stub_target_lookup(target)

      allow(containers).to receive(:find).with('ct1', 'tank').and_return(source)

      command = described_class.new({ id: 'ct1', pool: 'tank', target_id: 'ct1-copy' }, {})

      expect do
        command.execute(source)
      end.to raise_error(OsCtld::CommandFailed, /transfer in progress/)
    end

    it 'refuses to start when a local transfer is in progress' do
      source = source_ct(log: local_log(operation: :move))
      target = target_ct
      _pools, containers = stub_target_lookup(target)

      allow(containers).to receive(:find).with('ct1', 'tank').and_return(source)

      command = described_class.new({ id: 'ct1', pool: 'tank', target_id: 'ct1-copy' }, {})

      expect do
        command.execute(source)
      end.to raise_error(OsCtld::CommandFailed, /transfer in progress/)
    end
  end

  describe OsCtld::Commands::Container::MoveConfig do
    it 'opens a move transfer log' do
      source = source_ct
      target = target_ct
      _pools, containers = stub_target_lookup(target)
      builder = double(
        'Builder',
        valid?: true,
        errors: [],
        register: true,
        ctrc: double(dataset: target.dataset, map_mode: 'zfs'),
        setup_ct_dir: nil,
        setup_lxc_home: nil,
        setup_lxc_configs: nil,
        setup_log_file: nil,
        setup_user_hook_script_dir: nil,
        monitor: nil
      )
      builder_class = stub_const('OsCtld::Container::Builder', Class.new do
        def initialize(*, **); end
      end)

      allow(containers).to receive(:find).with('ct1', 'tank').and_return(source)
      allow(builder_class).to receive(:new).and_return(builder)
      allow(builder).to receive(:create_dataset)

      command = described_class.new({ id: 'ct1', pool: 'tank', target_id: 'ct1-copy' }, {})

      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(source.local_transfer_log.opts.operation).to eq(:move)
    end

    it 'refuses to start when a send transfer is in progress' do
      source = source_ct
      source.send_log = double('SendLog')
      target = target_ct
      _pools, containers = stub_target_lookup(target)

      allow(containers).to receive(:find).with('ct1', 'tank').and_return(source)

      command = described_class.new({ id: 'ct1', pool: 'tank', target_id: 'ct1-copy' }, {})

      expect do
        command.execute(source)
      end.to raise_error(OsCtld::CommandFailed, /transfer in progress/)
    end

    it 'refuses to start when a local transfer is in progress' do
      source = source_ct(log: local_log(operation: :copy))
      target = target_ct
      _pools, containers = stub_target_lookup(target)

      allow(containers).to receive(:find).with('ct1', 'tank').and_return(source)

      command = described_class.new({ id: 'ct1', pool: 'tank', target_id: 'ct1-copy' }, {})

      expect do
        command.execute(source)
      end.to raise_error(OsCtld::CommandFailed, /transfer in progress/)
    end
  end

  describe OsCtld::Commands::Container::CopyRootfs do
    it 'takes a base snapshot, transfers all datasets, and advances state' do
      child = OsCtld::LocalTransfer::Log::Dataset.new(
        relative_name: 'data',
        source: 'tank/ct/ct1/data',
        target: 'tank/ct/ct1-copy/data'
      )
      log = local_log(datasets: [transfer_opts[:datasets].first, child])
      source = source_ct(log:, descendants: [LocalTransferSpec::Dataset.new('tank/ct/ct1/data', 'data', [])])
      target = target_ct
      stub_target_lookup(target)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      transfers = []

      allow(command).to receive(:snapshot_name).with(:base).and_return('snap-base')
      allow(command).to receive(:zfs)
      allow(command).to receive(:transfer_dataset) { |pair, snap, **| transfers << [pair.relative_name, snap] }

      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(command).to have_received(:zfs).with(
        :snapshot,
        nil,
        'tank/ct/ct1@snap-base tank/ct/ct1/data@snap-base'
      )
      expect(transfers).to eq([['/', 'snap-base'], ['data', 'snap-base']])
      expect(log.snapshots).to eq(['snap-base'])
      expect(log.state).to eq(:base)
    end

    it 'fails when a copy command sees a move transfer log' do
      log = local_log(operation: :move)
      source = source_ct(log:)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})

      expect do
        command.execute(source)
      end.to raise_error(OsCtld::CommandFailed, 'local transfer is for move, not copy')
    end
  end

  describe OsCtld::Commands::Container::MoveRootfs do
    it 'fails when a move command sees a copy transfer log' do
      log = local_log(operation: :copy)
      source = source_ct(log:)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})

      expect do
        command.execute(source)
      end.to raise_error(OsCtld::CommandFailed, 'local transfer is for copy, not move')
    end
  end

  describe OsCtld::Commands::Container::CopySync do
    it 'is repeatable and transfers from the previous snapshot' do
      log = local_log(state: :base, snapshots: ['snap-base'])
      source = source_ct(log:)
      target = target_ct
      stub_target_lookup(target)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      transfers = []

      allow(command).to receive(:snapshot_name).and_return('snap-incr1', 'snap-incr2')
      allow(command).to receive(:zfs)
      allow(command).to receive(:transfer_dataset) do |pair, snap, from_snapshot: nil|
        transfers << [pair.relative_name, snap, from_snapshot]
      end

      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(transfers).to eq(
        [
          ['/', 'snap-incr1', 'snap-base'],
          ['/', 'snap-incr2', 'snap-incr1']
        ]
      )
      expect(log.state).to eq(:incremental)
    end

    it 'fails clearly when the dataset layout changes' do
      log = local_log(state: :base, snapshots: ['snap-base'])
      source = source_ct(log:, descendants: [LocalTransferSpec::Dataset.new('tank/ct/ct1/data', 'data', [])])
      target = target_ct
      stub_target_lookup(target)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})

      expect do
        command.execute(source)
      end.to raise_error(OsCtld::CommandFailed, /dataset layout changed/)
    end

    it 'fails when a copy command sees a move transfer log' do
      log = local_log(operation: :move, state: :base, snapshots: ['snap-base'])
      source = source_ct(log:)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})

      expect do
        command.execute(source)
      end.to raise_error(OsCtld::CommandFailed, 'local transfer is for move, not copy')
    end

    it 'requires rootfs to run before sync' do
      log = local_log(state: :stage)
      source = source_ct(log:)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})

      expect do
        command.execute(source)
      end.to raise_error(OsCtld::CommandFailed, 'invalid local transfer sequence')
    end
  end

  describe OsCtld::Commands::Container::CopyState do
    it 'restarts the source after the final snapshot before transfer' do
      stub_daemon
      log = local_log(state: :base, snapshots: ['snap-base'])
      source = source_ct(state: :running, log:)
      target = target_ct
      stub_target_lookup(target)
      command = described_class.new({ id: 'ct1', pool: 'tank', consistent: true, restart: true }, {})
      events = []

      allow(command).to receive(:snapshot_name).with(:state).and_return('snap-state')
      allow(command).to receive(:call_cmd!) { |klass, **kwargs| events << [:cmd, klass, kwargs] }
      allow(command).to receive(:zfs) { |op, *_args| events << [:zfs, op] }
      allow(command).to receive(:transfer_dataset) { |pair, snap, **kwargs| events << [:transfer, pair.relative_name, snap, kwargs] }

      expect(command.execute(source)).to eq(status: true, output: nil)

      start_idx = events.index do |event|
        event[0] == :cmd && event[1] == OsCtld::Commands::Container::Start
      end
      transfer_idx = events.index { |event| event[0] == :transfer }

      expect(start_idx).to be < transfer_idx
      expect(log.state_snapshot).to eq('snap-state')
      expect(log.state).to eq(:transfer)
      expect(target.state).to eq(:stopped)
    end

    it 'does not stop a running source with no consistency requested' do
      stub_daemon
      log = local_log(state: :base, snapshots: ['snap-base'])
      source = source_ct(state: :running, log:)
      target = target_ct
      stub_target_lookup(target)
      command = described_class.new({ id: 'ct1', pool: 'tank', consistent: false, restart: true }, {})

      allow(command).to receive(:snapshot_name).and_return('snap-state')
      allow(command).to receive(:zfs)
      allow(command).to receive(:transfer_dataset)
      allow(command).to receive(:call_cmd!)

      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(command).not_to have_received(:call_cmd!).with(OsCtld::Commands::Container::Stop, any_args)
    end

    it 'keeps the log open when stop fails' do
      stub_daemon
      log = local_log(state: :base, snapshots: ['snap-base'])
      source = source_ct(state: :running, log:)
      target = target_ct
      stub_target_lookup(target)
      command = described_class.new({ id: 'ct1', pool: 'tank', consistent: true }, {})

      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_raise(OsCtld::CommandFailed, 'stop failed')

      expect do
        command.execute(source)
      end.to raise_error(OsCtld::CommandFailed, 'stop failed')
      expect(source.local_transfer_log).to eq(log)
      expect(log.state_snapshot).to be_nil
      expect(log.state_running).to be(true)
    end

    it 'requires rootfs to run before state' do
      log = local_log(state: :stage)
      source = source_ct(log:)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})

      expect do
        command.execute(source)
      end.to raise_error(OsCtld::CommandFailed, 'invalid local transfer sequence')
    end

    it 'keeps a retryable state snapshot when restart fails' do
      stub_daemon
      log = local_log(state: :base, snapshots: ['snap-base'])
      source = source_ct(state: :running, log:)
      target = target_ct
      stub_target_lookup(target)
      command = described_class.new({ id: 'ct1', pool: 'tank', consistent: true, restart: true }, {})

      allow(command).to receive(:snapshot_name).and_return('snap-state')
      allow(command).to receive(:zfs)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!)
        .with(
          OsCtld::Commands::Container::Start,
          id: 'ct1',
          pool: 'tank',
          force: true,
          wait: false
        ).and_raise(OsCtld::CommandFailed, 'start failed')
      allow(command).to receive(:transfer_dataset)

      expect do
        command.execute(source)
      end.to raise_error(OsCtld::CommandFailed, 'start failed')
      expect(log.state_snapshot).to eq('snap-state')
      expect(command).not_to have_received(:transfer_dataset)
    end

    it 'clears a failed state snapshot before retrying' do
      stub_daemon
      log = local_log(
        state: :base,
        snapshots: ['snap-base'],
        state_snapshot: 'snap-failed',
        state_running: true
      )
      source = source_ct(state: :stopped, log:)
      target = target_ct
      stub_target_lookup(target)
      command = described_class.new({ id: 'ct1', pool: 'tank', consistent: true, restart: false }, {})
      destroys = []

      allow(command).to receive(:snapshot_name).and_return('snap-state')
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:zfs) do |op, _opts, target_name, **|
        destroys << target_name if op == :destroy
      end
      allow(command).to receive(:transfer_dataset)

      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(destroys).to include('tank/ct/ct1@snap-failed', 'tank/ct/ct1-copy@snap-failed')
      expect(log.state_snapshot).to eq('snap-state')
    end
  end

  describe OsCtld::Commands::Container::MoveState do
    it 'stops the source and starts the completed target when requested' do
      stub_daemon
      log = local_log(operation: :move, state: :base, snapshots: ['snap-base'])
      source = source_ct(state: :running, log:)
      target = target_ct
      stub_target_lookup(target)
      command = described_class.new({ id: 'ct1', pool: 'tank', start: true }, {})
      events = []

      allow(command).to receive(:snapshot_name).and_return('snap-state')
      allow(command).to receive(:call_cmd!) { |klass, **kwargs| events << [klass, kwargs] }
      allow(command).to receive(:zfs)
      allow(command).to receive(:transfer_dataset)

      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(events).to include([OsCtld::Commands::Container::Stop, { id: 'ct1', pool: 'tank' }])
      expect(events).to include([OsCtld::Commands::Container::Start, { id: 'ct1-copy', pool: 'tank', force: true }])
      expect(events).not_to include([OsCtld::Commands::Container::Start, hash_including(id: 'ct1')])
    end

    it 'does not start the target with start disabled' do
      stub_daemon
      log = local_log(operation: :move, state: :base, snapshots: ['snap-base'])
      source = source_ct(state: :running, log:)
      target = target_ct
      stub_target_lookup(target)
      command = described_class.new({ id: 'ct1', pool: 'tank', start: false }, {})

      allow(command).to receive(:snapshot_name).and_return('snap-state')
      allow(command).to receive(:call_cmd!)
      allow(command).to receive(:zfs)
      allow(command).to receive(:transfer_dataset)

      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(command).not_to have_received(:call_cmd!).with(
        OsCtld::Commands::Container::Start,
        hash_including(id: 'ct1-copy')
      )
    end
  end

  describe OsCtld::Commands::Container::CopyCleanup do
    it 'destroys source and target snapshots and closes the log' do
      log = local_log(state: :transfer, snapshots: %w[snap-base snap-incr], state_snapshot: 'snap-state')
      source = source_ct(log:)
      target = target_ct
      stub_target_lookup(target)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      destroys = []

      allow(command).to receive(:zfs) do |op, _opts, target_name, **|
        destroys << target_name if op == :destroy
      end

      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(destroys).to include(
        'tank/ct/ct1@snap-base',
        'tank/ct/ct1@snap-incr',
        'tank/ct/ct1@snap-state',
        'tank/ct/ct1-copy@snap-base',
        'tank/ct/ct1-copy@snap-incr',
        'tank/ct/ct1-copy@snap-state'
      )
      expect(source.closed_local_transfer_log).to be(true)
    end
  end

  describe OsCtld::Commands::Container::MoveCleanup do
    it 'deletes the source after transfer cleanup' do
      log = local_log(operation: :move, state: :transfer, snapshots: ['snap-base'])
      source = source_ct(log:)
      target = target_ct
      stub_target_lookup(target)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})

      allow(command).to receive(:zfs)
      allow(command).to receive(:call_cmd!)

      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(command).to have_received(:call_cmd!).with(
        OsCtld::Commands::Container::Delete,
        id: 'ct1',
        pool: 'tank',
        force: true
      )
    end
  end

  describe OsCtld::Commands::Container::CopyCancel do
    it 'destroys the staged target and closes the log' do
      log = local_log(state: :base, snapshots: ['snap-base'])
      source = source_ct(log:)
      target = target_ct
      stub_target_lookup(target)
      builder = double('Builder', cleanup: nil)
      builder_class = stub_const('OsCtld::Container::Builder', Class.new do
        def initialize(*, **); end
      end)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})

      allow(builder_class).to receive(:new).with(target, cmd: command).and_return(builder)
      allow(command).to receive(:zfs)

      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(builder).to have_received(:cleanup).with(dataset: true)
      expect(source.closed_local_transfer_log).to be(true)
    end

    it 'preserves a custom target dataset' do
      opts = transfer_opts.merge(target_dataset_custom: true)
      log = OsCtld::LocalTransfer::Log.new(role: :source, state: :base, snapshots: ['snap-base'], opts:)
      source = source_ct(log:)
      target = target_ct
      stub_target_lookup(target)
      builder = double('Builder', cleanup: nil)
      builder_class = stub_const('OsCtld::Container::Builder', Class.new do
        def initialize(*, **); end
      end)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})

      allow(builder_class).to receive(:new).with(target, cmd: command).and_return(builder)
      allow(command).to receive(:zfs)

      expect(command.execute(source)).to eq(status: true, output: nil)
      expect(builder).to have_received(:cleanup).with(dataset: false)
    end
  end
end

# rubocop:enable RSpec/DescribeClass, RSpec/VerifiedDoubles
