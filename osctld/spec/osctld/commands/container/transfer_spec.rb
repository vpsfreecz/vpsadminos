# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass

require 'stringio'
require 'osctld/command'
require 'osctld/exceptions'
require 'osctld/commands/container/export'
require 'osctld/commands/container/copy'
require 'osctld/commands/container/send_state'

RSpec.describe 'container transfer commands' do
  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  def stub_transfer_daemon(writeout:)
    config = Struct.new(:writeout) do
      def writeout_dirtied_pages?
        writeout
      end

      def send_receive
        Struct.new(:send_mbuffer).new(nil)
      end
    end.new(writeout)
    daemon = Struct.new(:config).new(config)

    stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
  end

  def build_dataset(name, descendants: [])
    Struct.new(:name, :descendants, :relative_name) do
      def to_s
        name
      end
    end.new(name, descendants, File.basename(name))
  end

  def build_send_ct(state: :running, snapshots: ['snap-base'], descendants: [], state_snapshot: nil, state_running: nil)
    send_log_opts = Struct.new(:cloned, :snapshots).new(false, false)
    send_log = Struct.new(:state, :snapshots, :opts, :token, :state_snapshot, :state_running) do
      def can_send_continue?(stage)
        case stage
        when :incremental
          %i[base incremental].include?(state)
        when :transfer
          state == :incremental
        else
          false
        end
      end
    end.new(:base, snapshots.dup, send_log_opts, 'token-1', state_snapshot, state_running)
    dataset = build_dataset('tank/ct1', descendants:)

    Struct.new(
      :id, :pool, :state, :send_log, :dataset, :save_config_calls,
      :closed_send_log, keyword_init: true
    ) do
      def manipulate(_cmd, block:, &)
        yield
      end

      def exclusively(&block)
        block.call
      end

      def each_dataset(&block)
        block.call(dataset)
        dataset.descendants.each(&block)
      end

      def close_send_log
        self.closed_send_log = true
      end

      def save_config
        self.save_config_calls += 1
      end
    end.new(
      id: 'ct1',
      pool: Struct.new(:name, :send_receive_key_chain).new('tank', nil),
      state:,
      send_log:,
      dataset:,
      save_config_calls: 0,
      closed_send_log: false
    )
  end

  def stub_send_ssh(command, transfer_success:)
    calls = []

    allow(command).to receive(:send_ssh_cmd) do |_key_chain, _opts, argv|
      calls << argv

      raise "unexpected ssh command #{argv.inspect}" unless argv[1] == 'transfer'

      exitstatus = transfer_success ? 0 : 1

      ['sh', '-c', "exit #{exitstatus}"]
    end

    calls
  end

  describe OsCtld::Commands::Container::Export do
    it 'aborts consistent exports when stopping the source container fails' do
      stop_class = Class.new
      stub_const('OsCtld::Commands::Container::Stop', stop_class)
      hook_manager = Class.new do
        def self.list_all_scripts(_ct); end
      end
      stub_const('OsCtld::Hook::Manager', hook_manager)
      ct = Struct.new(:id, :pool, :state, keyword_init: true).new(
        id: 'ct1',
        pool: Struct.new(:name).new('tank'),
        state: :running
      )
      exporter = instance_double(OsCtl::Lib::Exporter::Zfs)
      command = described_class.new({ consistent: true, compression: nil }, {})

      allow(OsCtl::Lib::Exporter::Zfs).to receive(:new).and_return(exporter)
      allow(OsCtld::Hook::Manager).to receive(:list_all_scripts).and_return([])
      allow(exporter).to receive(:dump_metadata)
      allow(exporter).to receive(:dump_configs)
      allow(exporter).to receive(:dump_user_hook_scripts)
      allow(exporter).to receive(:dump_rootfs).and_yield
      allow(exporter).to receive(:dump_base)
      allow(exporter).to receive(:dump_incremental)
      allow(exporter).to receive(:close)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_raise(OsCtld::CommandFailed, 'stop failed')

      expect do
        command.send(:export, ct, StringIO.new)
      end.to raise_error(OsCtld::CommandFailed, 'stop failed')
      expect(exporter).not_to have_received(:dump_incremental)
    end

    it 'aborts consistent exports when restarting the source container fails' do
      stop_class = Class.new
      start_class = Class.new
      stub_const('OsCtld::Commands::Container::Stop', stop_class)
      stub_const('OsCtld::Commands::Container::Start', start_class)
      hook_manager = Class.new do
        def self.list_all_scripts(_ct); end
      end
      stub_const('OsCtld::Hook::Manager', hook_manager)
      ct = Struct.new(:id, :pool, :state, keyword_init: true).new(
        id: 'ct1',
        pool: Struct.new(:name).new('tank'),
        state: :running
      )
      exporter = instance_double(OsCtl::Lib::Exporter::Zfs)
      command = described_class.new({ consistent: true, compression: nil }, {})

      allow(OsCtl::Lib::Exporter::Zfs).to receive(:new).and_return(exporter)
      allow(OsCtld::Hook::Manager).to receive(:list_all_scripts).and_return([])
      allow(exporter).to receive(:dump_metadata)
      allow(exporter).to receive(:dump_configs)
      allow(exporter).to receive(:dump_user_hook_scripts)
      allow(exporter).to receive(:dump_rootfs).and_yield
      allow(exporter).to receive(:dump_base)
      allow(exporter).to receive(:dump_incremental)
      allow(exporter).to receive(:close)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!)
        .with(
          OsCtld::Commands::Container::Start,
          id: 'ct1',
          pool: 'tank',
          force: true
        ).and_raise(OsCtld::CommandFailed, 'start failed')

      expect do
        command.send(:export, ct, StringIO.new)
      end.to raise_error(OsCtld::CommandFailed, 'start failed')
      expect(exporter).to have_received(:dump_incremental)
    end
  end

  describe OsCtld::Commands::Container::SendState do
    before do
      stub_transfer_daemon(writeout: false)
      stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      stub_const('OsCtld::Commands::Container::Stop', Class.new)
      stub_const('OsCtld::Commands::Container::Start', Class.new)
    end

    it 'keeps the transfer open when stopping the source container fails' do
      ct = build_send_ct
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: true,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_raise(OsCtld::CommandFailed, 'stop failed')
      allow(command).to receive(:send_dataset)

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'stop failed')

      expect(command).not_to have_received(:send_dataset)
      expect(ct.closed_send_log).to be(false)
      expect(ct.send_log.snapshots).to eq(['snap-base'])
      expect(ct.send_log.state_snapshot).to be_nil
      expect(ct.send_log.state_running).to be(true)
    end

    it 'keeps a retryable cutover snapshot when restarting the source container fails' do
      ct = build_send_ct
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: true,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Start, id: 'ct1', pool: 'tank')
        .and_raise(OsCtld::CommandFailed, 'start failed')
      allow(command).to receive(:send_dataset)
      allow(command).to receive(:zfs)

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'start failed')

      expect(command).not_to have_received(:send_dataset)
      expect(ct.closed_send_log).to be(false)
      expect(ct.send_log.snapshots).to eq(['snap-base'])
      expect(ct.send_log.state_snapshot).to match(/^osctl-send-incr-/)
      expect(ct.send_log.state_running).to be(true)
    end

    it 'keeps the cutover retryable when the target handoff fails' do
      ct = build_send_ct
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: false,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )
      ssh_calls = stub_send_ssh(
        command,
        transfer_success: false
      )
      zfs_calls = []

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:send_dataset)
      allow(command).to receive(:zfs) do |op, _flag, target|
        zfs_calls << [op, target]
      end

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'transfer failed')

      snap = zfs_calls.detect { |op, _target| op == :snapshot }[1].split('@', 2).last
      destroy_calls = zfs_calls.filter_map do |op, target|
        target if op == :destroy
      end

      expect(ssh_calls).to eq([%w[receive transfer token-1]])
      expect(command).to have_received(:send_dataset).with(ct, ct.dataset, snap)
      expect(destroy_calls).to be_empty
      expect(ct.closed_send_log).to be(false)
      expect(ct.send_log.snapshots).to eq(['snap-base'])
      expect(ct.send_log.state_snapshot).to eq(snap)
      expect(ct.send_log.state_running).to be(true)
    end

    it 'drops the failed cutover snapshot before retrying' do
      ct = build_send_ct(state_snapshot: 'snap-failed')
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: false,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )
      ssh_calls = stub_send_ssh(
        command,
        transfer_success: true
      )
      zfs_calls = []

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:send_dataset)
      allow(command).to receive(:zfs) do |op, _flag, target|
        zfs_calls << [op, target]
      end

      expect(command.execute).to eq(status: true, output: nil)

      destroy_calls = zfs_calls.filter_map { |op, target| target if op == :destroy }
      snapshot_call = zfs_calls.detect do |op, target|
        op == :snapshot && target.start_with?('tank/ct1@')
      end
      snap = snapshot_call[1].split('@', 2).last

      expect(ssh_calls).to eq([%w[receive transfer token-1]])
      expect(destroy_calls).to include('tank/ct1@snap-failed')
      expect(ct.send_log.snapshots).to eq(['snap-base'])
      expect(ct.send_log.state_snapshot).to eq(snap)
      expect(ct.send_log.state).to eq(:transfer)
      expect(ct.send_log.state_running).to be(true)
    end

    it 'retries the target handoff with start again when requested' do
      ct = build_send_ct(state: :stopped, state_snapshot: 'snap-failed', state_running: true)
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: false,
          consistent: true,
          restart: true,
          start: true
        },
        {}
      )
      ssh_calls = stub_send_ssh(
        command,
        transfer_success: true
      )

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:send_dataset)
      allow(command).to receive(:zfs)

      expect(command.execute).to eq(status: true, output: nil)

      expect(ssh_calls).to eq([%w[receive transfer token-1 start]])
      expect(ct.send_log.state_running).to be(true)
    end

    it 'restarts the source on clone retry when the original cutover stopped it' do
      ct = build_send_ct(state: :stopped, state_snapshot: 'snap-failed', state_running: true)
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: true,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Start, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:send_dataset)
      allow(command).to receive(:zfs)
      stub_send_ssh(command, transfer_success: true)

      expect(command.execute).to eq(status: true, output: nil)

      expect(command).to have_received(:call_cmd!)
        .with(OsCtld::Commands::Container::Start, id: 'ct1', pool: 'tank')
    end
  end
end

# rubocop:enable RSpec/DescribeClass
