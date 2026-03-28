# frozen_string_literal: true

require 'osctld/lock_registry'
require 'osctld/lockable'
require 'osctld/net_interface'
require 'osctld/net_interface/base'
require 'osctld/net_interface/manager'

RSpec.describe OsCtld::NetInterface::Manager do
  let(:ct) { FakeObjects::FakeRuntimeContainer.new(pool: Struct.new(:name).new('tank'), id: 'ct1') }
  let(:managed_class) do
    Class.new(OsCtld::NetInterface::Base) do
      type :test_manager

      attr_reader :down_calls
      attr_writer :created

      def initialize(*)
        super
        @down_calls = 0
        @created = false
      end

      def setup
        @setup_called = true
      end

      def setup_called?
        @setup_called
      end

      def render_opts
        {}
      end

      def is_created?
        @created
      end

      def ips(_v)
        []
      end

      def add_ip(_addr); end

      def del_ip(_addr); end

      def down
        @down_calls += 1
      end
    end
  end

  before do
    allow(OsCtld::LockRegistry).to receive(:register)
    stub_const('OsCtld::Eventd', Module.new do
      def self.report(*); end
    end)
    allow(OsCtld::Eventd).to receive(:report)
  end

  it 'loads netifs through the registered type and runs setup' do
    OsCtld::NetInterface.register(:test_manager, managed_class)

    manager = described_class.load(
      ct,
      [
        {
          'type' => 'test_manager',
          'name' => 'eth0',
          'hwaddr' => nil,
          'max_tx' => 0,
          'max_rx' => 0,
          'enable' => true
        }
      ]
    )

    expect(manager['eth0'].class.type).to eq(:test_manager)
    expect(manager['eth0'].setup_called?).to be(true)
  end

  it 'adds, deletes, enumerates, dumps, and duplicates interfaces' do
    first = managed_class.new(ct, 0)
    first.create(name: 'eth0', hwaddr: nil)
    second = managed_class.new(ct, 1)
    second.create(name: 'eth1', hwaddr: nil)
    manager = described_class.new(ct)

    manager.add(first)
    manager << second

    expect(manager.contains?('eth0')).to be(true)
    expect(manager['eth1']).to eq(second)
    expect(manager.get).to eq([first, second])
    expect(manager.map(&:name)).to eq(%w[eth0 eth1])
    expect(manager.dump.map { |cfg| cfg['name'] }).to eq(%w[eth0 eth1])
    expect(ct.save_config_calls).to eq(2)

    other_ct = FakeObjects::FakeRuntimeContainer.new(pool: ct.pool, id: 'ct2')
    copy = manager.dup(other_ct)
    expect(copy.map(&:name)).to eq(%w[eth0 eth1])

    manager.delete(first)
    expect(manager.contains?('eth0')).to be(false)
  end

  it 'takes down only created interfaces' do
    created = managed_class.new(ct, 0)
    created.create(name: 'eth0', hwaddr: nil)
    created.created = true
    stopped = managed_class.new(ct, 1)
    stopped.create(name: 'eth1', hwaddr: nil)
    manager = described_class.new(ct, entries: [created, stopped])

    manager.take_down

    expect(created.down_calls).to eq(1)
    expect(stopped.down_calls).to eq(0)
  end
end
