# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/VerifiedDoubles

require 'tempfile'
require 'osctld/command'
require 'osctld/exceptions'

module OsCtld
  module Commands
    module Container; end
  end
end

require 'osctld/commands/container/recover_cleanup'
require 'osctld/commands/container/recover_state'
require 'osctld/commands/container/send_cancel'
require 'osctld/commands/container/send_cleanup'
require 'osctld/commands/container/send_config'
require 'osctld/commands/container/send_now'
require 'osctld/commands/container/send_rootfs'
require 'osctld/commands/container/send_sync'

RSpec.describe 'container recovery and send wrappers' do
  def build_send_ct(state: :stopped, send_log: nil, local_transfer_log: nil, descendants: [])
    dataset = Struct.new(:name, :descendants, :relative_name) do
      def to_s
        name
      end
    end.new('tank/ct1', descendants, 'ct1')

    Struct.new(
      :id, :pool, :state, :send_log, :local_transfer_log, :dataset, :user,
      :group, :opened_send_log, :closed_send_log, :save_config_calls,
      keyword_init: true
    ) do
      def manipulate(_holder, block:, &)
        yield
      end

      def exclusively
        yield
      end

      def each_dataset(&block)
        yield dataset
        dataset.descendants.each(&block)
      end

      def close_send_log
        self.closed_send_log = true
      end

      def open_send_log(type, token, opts)
        self.opened_send_log = [type, token, opts]
      end

      def transfer_in_progress?
        !!send_log || !!local_transfer_log
      end

      def save_config
        self.save_config_calls += 1
      end

      def dump_config
        {
          'user' => user.name,
          'group' => group.name,
          'net_interfaces' => [{ 'name' => 'eth0' }]
        }
      end
    end.new(
      id: 'ct1',
      pool: Struct.new(:name, :send_receive_key_chain).new('tank', nil),
      state:,
      send_log:,
      local_transfer_log:,
      dataset:,
      user: Struct.new(:name, :config_path).new('alice', '/configs/user.yml'),
      group: Struct.new(:name, :config_path).new('default', '/configs/group.yml'),
      opened_send_log: nil,
      closed_send_log: false,
      save_config_calls: 0
    )
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  describe OsCtld::Commands::Container::RecoverCleanup do
    it 'cleans up cgroups and stray netifs through the recovery helper' do
      recovery_class = stub_const('OsCtld::Container::Recovery', Class.new do
        def self.new(_ct); end
      end)
      route = Struct.new(:addr).new(Struct.new(:to_string).new('192.0.2.0/24'))
      result = {
        outcome: :cleaned,
        hazards: [],
        run_id: 'tank:ct1:run1'
      }
      recovery = double('Recovery')
      allow(recovery).to receive(:cleanup)
        .with(run_id: nil, cleanup: 'all', force: true, admission: {})
        .and_yield('veth0', [route])
        .and_return(result)
      ct = build_send_ct(state: :running)
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(recovery_class).to receive(:new).with(ct).and_return(recovery)

      command = described_class.new(
        { id: 'ct1', pool: 'tank', cleanup: 'all', force: true },
        {}
      )
      allow(command).to receive(:progress)

      expect(command.execute).to eq(status: true, output: result)
      expect(recovery).to have_received(:cleanup).with(
        run_id: nil,
        cleanup: 'all',
        force: true,
        admission: {}
      )
      expect(command).to have_received(:progress).with('veth0: 192.0.2.0/24')
    end
  end

  describe OsCtld::Commands::Container::RecoverState do
    it 'restores state through the recovery helper' do
      recovery_class = stub_const('OsCtld::Container::Recovery', Class.new do
        def self.new(_ct); end
      end)
      result = { state: :stopped, run_id: 'tank:ct1:run1' }
      recovery = double('Recovery')
      allow(recovery).to receive(:recover_state)
        .with(run_id: nil, admission: {})
        .and_return(result)
      ct = build_send_ct
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(recovery_class).to receive(:new).with(ct).and_return(recovery)

      expect(described_class.run(id: 'ct1', pool: 'tank')).to eq(
        status: true,
        output: result
      )
      expect(recovery).to have_received(:recover_state).with(
        run_id: nil,
        admission: {}
      )
    end
  end

  describe OsCtld::Commands::Container::SendCancel do
    it 'destroys transfer snapshots and closes the send log for local cancels' do
      send_opts = double('SendOpts')
      send_log = double(
        'SendLog',
        opts: send_opts,
        token: 'token-1',
        snapshots: %w[snap1 snap2],
        state_snapshot: nil
      )
      allow(send_log).to receive(:can_send_cancel?).with(false).and_return(true)
      ct = build_send_ct(send_log:)
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      command = described_class.new({ id: 'ct1', pool: 'tank', local: true, force: false }, {})
      allow(command).to receive(:zfs)

      expect(command.execute).to eq(status: true, output: nil)
      expect(command).to have_received(:zfs).with(:destroy, nil, 'tank/ct1@snap1')
      expect(command).to have_received(:zfs).with(:destroy, nil, 'tank/ct1@snap2')
      expect(ct.closed_send_log).to be(true)
    end
  end

  describe OsCtld::Commands::Container::SendCleanup do
    def build_send_cleanup_log(opts:, snapshots:, state_snapshot:, token:, state:)
      Struct.new(:opts, :snapshots, :state_snapshot, :token, :state) do
        def can_send_continue?(stage)
          stage == :cleanup && %i[incremental transfer cleanup].include?(state)
        end
      end.new(opts, snapshots, state_snapshot, token, state)
    end

    it 'finalizes the target, destroys snapshots, and deletes uncloned transfers' do
      send_opts = double('SendOpts', cloned?: false)
      send_log = build_send_cleanup_log(
        opts: send_opts,
        snapshots: ['snap1'],
        state_snapshot: nil,
        token: 'token-1',
        state: :transfer
      )
      ct = build_send_ct(send_log:)
      delete_class = stub_const('OsCtld::Commands::Container::Delete', Class.new)
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:zfs)
      allow(command).to receive(:send_ssh_cmd)
        .with(nil, send_opts, %w[receive cleanup token-1])
        .and_return(['sh', '-c', 'exit 0'])
      allow(command).to receive(:call_cmd!).with(delete_class, pool: 'tank', id: 'ct1').and_return(status: true, output: nil)

      expect(command.execute).to eq(status: true, output: nil)
      expect(command).to have_received(:send_ssh_cmd)
        .with(nil, send_opts, %w[receive cleanup token-1])
      expect(ct.closed_send_log).to be(true)
      expect(command).to have_received(:call_cmd!).with(delete_class, pool: 'tank', id: 'ct1')
    end

    it 'also destroys a pending cutover snapshot during cleanup' do
      send_opts = double('SendOpts', cloned?: true)
      send_log = build_send_cleanup_log(
        opts: send_opts,
        snapshots: ['snap1'],
        state_snapshot: 'snap-cutover',
        token: 'token-1',
        state: :incremental
      )
      ct = build_send_ct(send_log:)
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:zfs)

      expect(command.execute).to eq(status: true, output: nil)
      expect(command).to have_received(:zfs).with(:destroy, nil, 'tank/ct1@snap-cutover', valid_rcs: [1])
      expect(ct.closed_send_log).to be(true)
    end
  end

  describe OsCtld::Commands::Container::SendConfig do
    it 'refuses to start when a send transfer is in progress' do
      ct = build_send_ct(send_log: double('SendLog'))
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      command = described_class.new({ id: 'ct1', pool: 'tank', dst: 'example.org' }, {})

      expect(command.execute).to eq(
        status: false,
        message: 'this container already has a transfer in progress'
      )
    end

    it 'refuses to start when a local transfer is in progress' do
      ct = build_send_ct(local_transfer_log: double('LocalTransferLog'))
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      command = described_class.new({ id: 'ct1', pool: 'tank', dst: 'example.org' }, {})

      expect(command.execute).to eq(
        status: false,
        message: 'this container already has a transfer in progress'
      )
    end

    it 'strips @ from from_snapshot and opens the send log on success' do
      ct = build_send_ct(send_log: nil)
      hook_manager = stub_const('OsCtld::Hook::Manager', Class.new do
        def self.list_all_scripts(_ct); end
      end)
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(hook_manager).to receive(:list_all_scripts).with(ct).and_return([])
      allow(File).to receive(:read).with('/configs/user.yml').and_return("user: alice\n")
      allow(File).to receive(:read).with('/configs/group.yml').and_return("group: default\n")

      command = described_class.new(
        { id: 'ct1', pool: 'tank', dst: 'example.org', from_snapshot: '@base-snap' },
        {}
      )
      allow(command).to receive(:send_ssh_cmd).and_return(['sh', '-c', "'cat >/dev/null; echo token-1'"])
      allow(command).to receive(:export) do |_ct, io, *_args, **_kwargs|
        io.write('payload')
      end

      expect(command.execute).to eq(status: true, output: nil)
      expect(ct.opened_send_log[0]).to eq(:source)
      expect(ct.opened_send_log[1]).to eq('token-1')
      expect(ct.opened_send_log[2]).to include(
        dst: 'example.org',
        from_snapshot: 'base-snap',
        protocol_version: OsCtld::SendReceive::PROTOCOL_VERSION
      )
    end
  end

  describe OsCtld::Commands::Container::SendNow do
    it 'runs config, rootfs, state, and cleanup in order with step progress' do
      send_config = stub_const('OsCtld::Commands::Container::SendConfig', Class.new)
      send_rootfs = stub_const('OsCtld::Commands::Container::SendRootfs', Class.new)
      send_state = stub_const('OsCtld::Commands::Container::SendState', Class.new)
      send_cleanup = stub_const('OsCtld::Commands::Container::SendCleanup', Class.new)
      ct = build_send_ct
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      command = described_class.new(
        { id: 'ct1', pool: 'tank', dst: 'example.org', clone: true, restart: false, start: true },
        {}
      )
      allow(command).to receive(:progress)
      allow(command).to receive(:call_cmd!).with(
        send_config,
        id: 'ct1',
        pool: 'tank',
        dst: 'example.org',
        port: nil,
        passphrase: nil,
        as_id: nil,
        to_pool: nil,
        network_interfaces: nil,
        snapshots: nil,
        from_snapshot: nil,
        preexisting_datasets: nil
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(send_rootfs, id: 'ct1', pool: 'tank').and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        send_state,
        id: 'ct1',
        pool: 'tank',
        clone: true,
        restart: false,
        start: true
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(send_cleanup, id: 'ct1', pool: 'tank').and_return(status: true, output: nil)

      expect(command.execute).to eq(status: true, output: nil)
      expect(command).to have_received(:progress).with(type: :step, title: 'Sending config')
      expect(command).to have_received(:progress).with(type: :step, title: 'Sending rootfs')
      expect(command).to have_received(:progress).with(type: :step, title: 'Sending state')
      expect(command).to have_received(:progress).with(type: :step, title: 'Cleaning up')
    end
  end

  describe OsCtld::Commands::Container::SendRootfs do
    it 'takes a base snapshot, syncs all datasets, and advances the send state' do
      send_log = Struct.new(:state, :snapshots, :opts) do
        def can_send_continue?(stage)
          stage == :base
        end
      end.new(
        nil,
        [],
        double(
          'SendOpts',
          from_snapshot: nil,
          preexisting_datasets: false,
          snapshots: false
        )
      )
      child = Struct.new(:name, :descendants, :relative_name) do
        def to_s
          name
        end
      end.new('tank/ct1/sub', [], 'sub')
      ct = build_send_ct(send_log:, descendants: [child])
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:zfs)
      allow(command).to receive(:send_dataset)

      expect(command.execute).to eq(status: true, output: nil)
      expect(command).to have_received(:send_dataset).with(ct, ct.dataset, kind_of(String))
      expect(command).to have_received(:send_dataset).with(ct, child, kind_of(String))
      expect(send_log.state).to eq(:base)
      expect(ct.save_config_calls).to eq(2)
    end

    it 'sends from a selected snapshot before the temporary base snapshot' do
      send_log = Struct.new(:state, :snapshots, :opts) do
        def can_send_continue?(stage)
          stage == :base
        end
      end.new(
        nil,
        [],
        double(
          'SendOpts',
          from_snapshot: 'vpsadmin-replace',
          preexisting_datasets: false,
          snapshots: false
        )
      )
      ct = build_send_ct(send_log:)
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      transfers = []

      allow(command).to receive(:zfs)
      allow(command).to receive(:send_snapshot) do |_ct, ds, base_snap, snap, from_snap = nil|
        transfers << [ds.relative_name, base_snap, snap, from_snap]
      end

      expect(command.execute).to eq(status: true, output: nil)
      expect(transfers).to match(
        [
          ['ct1', kind_of(String), 'vpsadmin-replace', nil],
          ['ct1', kind_of(String), kind_of(String), 'vpsadmin-replace']
        ]
      )
      expect(send_log.snapshots.count).to eq(1)
    end
  end

  describe OsCtld::Commands::Container::SendSync do
    it 'takes incremental snapshots, syncs descendants, and advances the send state' do
      send_log = Struct.new(:state, :snapshots, :opts) do
        def can_send_continue?(stage)
          stage == :incremental
        end
      end.new(nil, ['snap-prev'], double('SendOpts', snapshots: false))
      child = Struct.new(:name, :descendants, :relative_name) do
        def to_s
          name
        end
      end.new('tank/ct1/sub', [], 'sub')
      ct = build_send_ct(send_log:, descendants: [child])
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:zfs)
      allow(command).to receive(:send_dataset)

      expect(command.execute).to eq(status: true, output: nil)
      expect(command).to have_received(:send_dataset).with(ct, ct.dataset, kind_of(String))
      expect(command).to have_received(:send_dataset).with(ct, child, kind_of(String))
      expect(send_log.state).to eq(:incremental)
      expect(ct.save_config_calls).to eq(2)
    end
  end
end

# rubocop:enable RSpec/DescribeClass, RSpec/VerifiedDoubles
