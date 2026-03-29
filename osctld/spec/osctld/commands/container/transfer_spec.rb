# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass

require 'stringio'
require 'osctld/exceptions'
require 'osctld/commands/container/export'
require 'osctld/commands/container/copy'
require 'osctld/commands/container/send_state'

RSpec.describe 'container transfer commands' do
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
  end

  describe OsCtld::Commands::Container::Copy do
    it 'aborts consistent copies when stopping the source container fails' do
      stub_transfer_daemon(writeout: false)
      stop_class = Class.new
      stub_const('OsCtld::Commands::Container::Stop', stop_class)
      src_dataset = instance_double(OsCtl::Lib::Zfs::Dataset, name: 'tank/ct1', descendants: [])
      ct = Struct.new(:dataset, :datasets, :id, :pool, keyword_init: true) do
        def running?
          true
        end
      end.new(
        dataset: src_dataset,
        datasets: [src_dataset],
        id: 'ct1',
        pool: Struct.new(:name).new('tank')
      )
      target_dataset = instance_double(OsCtl::Lib::Zfs::Dataset, name: 'tank/target/ct1')
      ctrc = Struct.new(:dataset, :map_mode).new(target_dataset, 'zfs')
      builder_class = Class.new do
        def ctrc; end

        def create_dataset(*, **); end

        def copy_datasets(*, **); end
      end
      builder = instance_double(builder_class, ctrc:)
      command = described_class.new({ consistent: true, restart: true }, {})
      destroy_calls = []

      allow(builder).to receive(:create_dataset)
      allow(builder).to receive(:copy_datasets).and_return('snap1')
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_raise(OsCtld::CommandFailed, 'stop failed')
      allow(command).to receive(:zfs) do |op, _flag, target|
        destroy_calls << target if op == :destroy
      end

      expect do
        command.send(:copy_datasets_from, builder, ct)
      end.to raise_error(OsCtld::CommandFailed, 'stop failed')
      expect(builder).to have_received(:copy_datasets).once
      expect(destroy_calls).to eq(
        %w[
          tank/ct1@snap1
          tank/target/ct1@snap1
        ]
      )
    end
  end

  describe OsCtld::Commands::Container::SendState do
    def build_ct
      send_log_opts = Struct.new(:cloned, :snapshots).new(false, false)
      send_log = Struct.new(:state, :snapshots, :opts) do
        def can_send_continue?(stage)
          %i[incremental transfer].include?(stage)
        end
      end.new(nil, [], send_log_opts)
      dataset = Struct.new(:name, :descendants, :relative_name) do
        def to_s
          name
        end
      end.new('tank/ct1', [], 'ct1')

      Struct.new(:id, :pool, :state, :send_log, :dataset, :save_config_calls, keyword_init: true) do
        def manipulate(_cmd, block:, &)
          yield
        end

        def exclusively(&block)
          block.call
        end

        def save_config
          self.save_config_calls += 1
        end
      end.new(
        id: 'ct1',
        pool: Struct.new(:name, :send_receive_key_chain).new('tank', nil),
        state: :running,
        send_log:,
        dataset:,
        save_config_calls: 0
      )
    end

    before do
      stub_transfer_daemon(writeout: false)
      stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      stub_const('OsCtld::Commands::Container::Stop', Class.new)
      stub_const('OsCtld::Commands::Container::Start', Class.new)
    end

    it 'aborts before taking snapshots when stopping the container fails' do
      ct = build_ct
      command = described_class.new(
        { id: 'ct1', pool: 'tank', clone: true, consistent: true, restart: true, start: false },
        {}
      )
      allow(OsCtld::DB::Containers).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_raise(OsCtld::CommandFailed, 'stop failed')
      allow(command).to receive(:zfs)
      allow(command).to receive(:send_dataset)

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'stop failed')
      expect(command).not_to have_received(:zfs)
      expect(command).not_to have_received(:send_dataset)
    end

    it 'aborts before transfer when restarting the container fails' do
      ct = build_ct
      command = described_class.new(
        { id: 'ct1', pool: 'tank', clone: true, consistent: true, restart: true, start: false },
        {}
      )
      allow(OsCtld::DB::Containers).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Start, id: 'ct1', pool: 'tank')
        .and_raise(OsCtld::CommandFailed, 'start failed')
      allow(command).to receive(:zfs)
      allow(command).to receive(:send_dataset)

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'start failed')
      expect(command).to have_received(:zfs).with(:snapshot, '-r', %r{tank/ct1@osctl-send-incr-})
      expect(command).not_to have_received(:send_dataset)
    end
  end
end

# rubocop:enable RSpec/DescribeClass
