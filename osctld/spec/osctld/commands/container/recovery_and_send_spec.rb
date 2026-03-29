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
  def build_send_ct(state: :stopped, send_log: nil, descendants: [])
    dataset = Struct.new(:name, :descendants, :relative_name) do
      def to_s
        name
      end
    end.new('tank/ct1', descendants, 'ct1')

    Struct.new(
      :id, :pool, :state, :send_log, :dataset, :user, :group,
      :opened_send_log, :closed_send_log, :save_config_calls,
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
      recovery = double('Recovery', cleanup_cgroups: nil)
      allow(recovery).to receive(:cleanup_netifs).and_yield('veth0', [route])
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

      expect(command.execute).to eq(status: true, output: nil)
      expect(recovery).to have_received(:cleanup_cgroups)
      expect(command).to have_received(:progress).with('Searching for stray network interfaces')
      expect(command).to have_received(:progress).with('veth0: 192.0.2.0/24')
    end
  end

  describe OsCtld::Commands::Container::RecoverState do
    it 'restores state through the recovery helper' do
      recovery_class = stub_const('OsCtld::Container::Recovery', Class.new do
        def self.new(_ct); end
      end)
      recovery = double('Recovery', recover_state: nil)
      ct = build_send_ct
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(recovery_class).to receive(:new).with(ct).and_return(recovery)

      expect(described_class.run(id: 'ct1', pool: 'tank')).to eq(status: true, output: nil)
      expect(recovery).to have_received(:recover_state)
    end
  end

  describe OsCtld::Commands::Container::SendCancel do
    it 'destroys transfer snapshots and closes the send log for local cancels' do
      send_opts = double('SendOpts')
      send_log = double('SendLog', opts: send_opts, token: 'token-1', snapshots: %w[snap1 snap2])
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
    it 'destroys snapshots, closes the send log, and deletes uncloned transfers' do
      send_opts = double('SendOpts', cloned?: false)
      send_log = double('SendLog', opts: send_opts, snapshots: ['snap1'])
      allow(send_log).to receive(:can_send_continue?).with(:cleanup).and_return(true)
      ct = build_send_ct(send_log:)
      delete_class = stub_const('OsCtld::Commands::Container::Delete', Class.new)
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:zfs)
      allow(command).to receive(:call_cmd!).with(delete_class, pool: 'tank', id: 'ct1').and_return(status: true, output: nil)

      expect(command.execute).to eq(status: true, output: nil)
      expect(ct.closed_send_log).to be(true)
      expect(command).to have_received(:call_cmd!).with(delete_class, pool: 'tank', id: 'ct1')
    end
  end

  describe OsCtld::Commands::Container::SendConfig do
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
      expect(ct.opened_send_log[2]).to include(dst: 'example.org', from_snapshot: 'base-snap')
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
      end.new(nil, [], double('SendOpts', from_snapshot: nil, preexisting_datasets: false, snapshots: false))
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
