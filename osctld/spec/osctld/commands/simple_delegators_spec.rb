# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/commands/self/ping'
require 'osctld/commands/debug/lock_registry'
require 'osctld/commands/history/list'
require 'osctld/commands/trash_bin/prune'
require 'osctld/commands/trash_bin/dataset_add'
require 'osctld/commands/garbage_collector/prune'
require 'osctld/commands/send/key_path'
require 'osctld/commands/receive/authkey_list'

RSpec.describe OsCtld::Commands::Self::Ping do
  it 'returns pong from self ping' do
    expect(described_class.run).to eq(status: true, output: 'pong')
  end

  it 'exports lock registry data with denixstorified backtraces' do
    lock = { backtrace: ['/nix/store/foo', '/tmp/bar'] }
    command = OsCtld::Commands::Debug::LockRegistry.new({}, {})

    allow(OsCtld::LockRegistry).to receive_messages(
      enabled?: true,
      export: [lock]
    )
    allow(command).to receive(:denixstorify).with(lock[:backtrace]).and_return(%w[foo bar])

    expect(command.execute).to eq(status: true, output: [{ backtrace: %w[foo bar] }])
  end

  it 'merges and sorts history entries by time and pool name' do
    pool1 = Struct.new(:name, keyword_init: true).new(name: 'tank')
    pool2 = Struct.new(:name, keyword_init: true).new(name: 'pool2')
    reader_class = Class.new do
      attr_reader :entries

      def initialize(entries)
        @entries = entries
      end
    end
    reader1 = reader_class.new([{ time: 2, event: :b }])
    reader2 = reader_class.new([{ time: 1, event: :a }])

    stub_const('OsCtld::DB::Pools', Class.new do
      def self.get; end

      def self.find(_name); end
    end)
    history = stub_const('OsCtld::History', Module.new)
    history.define_singleton_method(:read) { |_pool| nil }
    allow(OsCtld::DB::Pools).to receive(:get).and_return([pool1, pool2])
    allow(OsCtld::History).to receive(:read).with(pool1).and_return(reader1)
    allow(OsCtld::History).to receive(:read).with(pool2).and_return(reader2)

    ret = OsCtld::Commands::History::List.run

    expect(ret[:output]).to eq(
      [
        { time: 1, event: :a, pool: 'pool2' },
        { time: 2, event: :b, pool: 'tank' }
      ]
    )
  end

  it 'delegates trash-bin and garbage-collector prune commands to pools' do
    trash = Struct.new(:prune).new
    gc = Struct.new(:prune).new
    pool = Struct.new(:trash_bin, :garbage_collector).new(trash, gc)

    allow(trash).to receive(:prune)
    allow(gc).to receive(:prune)
    stub_const('OsCtld::DB::Pools', Class.new do
      def self.get; end
    end)
    allow(OsCtld::DB::Pools).to receive(:get).and_return([pool])

    expect(OsCtld::Commands::TrashBin::Prune.run).to eq(status: true, output: nil)
    expect(OsCtld::Commands::GarbageCollector::Prune.run).to eq(status: true, output: nil)
    expect(trash).to have_received(:prune).once
    expect(gc).to have_received(:prune).once
  end

  it 'adds datasets to the trash bin through the resolved pool' do
    dataset = Struct.new(:name, :pool) do
      def is_pool?
        false
      end
    end.new('tank/ct1', 'tank')
    trash = Class.new do
      def add_dataset(_dataset); end
    end.new
    pool = Struct.new(:trash_bin).new(trash)

    allow(trash).to receive(:add_dataset)
    stub_const('OsCtl::Lib::Zfs::Dataset', Class.new do
      def initialize(*); end
    end)
    allow(OsCtl::Lib::Zfs::Dataset).to receive(:new).with('tank/ct1').and_return(dataset)
    stub_const('OsCtld::DB::Pools', Class.new do
      def self.find(_name); end
    end)
    allow(OsCtld::DB::Pools).to receive(:find).with('tank').and_return(pool)

    expect(OsCtld::Commands::TrashBin::DatasetAdd.run(dataset: 'tank/ct1')).to eq(
      status: true,
      output: nil
    )
    expect(trash).to have_received(:add_dataset).with(dataset)
  end

  it 'returns send key paths and receive auth key exports for the selected pool' do
    key_chain = Struct.new(:private_key_path, :public_key_path, :export, keyword_init: true).new(
      private_key_path: '/keys/id_rsa',
      public_key_path: '/keys/id_rsa.pub',
      export: [{ name: 'rx' }]
    )
    pool = Struct.new(:send_receive_key_chain).new(key_chain)

    stub_const('OsCtld::DB::Pools', Class.new do
      def self.find(_name); end

      def self.get_or_default(_name); end
    end)
    allow(OsCtld::DB::Pools).to receive(:get_or_default).with(nil).and_return(pool)

    expect(OsCtld::Commands::Send::KeyPath.run).to eq(
      status: true,
      output: {
        private_key: '/keys/id_rsa',
        public_key: '/keys/id_rsa.pub'
      }
    )
    expect(OsCtld::Commands::Receive::AuthKeyList.run).to eq(
      status: true,
      output: [{ name: 'rx' }]
    )
  end
end
