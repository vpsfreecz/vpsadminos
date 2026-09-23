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

      def setup(**)
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
  let(:claiming_class) do
    Class.new(managed_class) do
      type :test_manager_claim

      def load(cfg)
        super
        @host_link_identity = cfg.fetch('host_link_identity')
      end

      attr_reader :host_link_identity
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

  [
    [
      'name',
      ['veth0', 10, nil],
      ['veth0', 11, nil]
    ],
    [
      'ifindex',
      ['veth0', 10, nil],
      ['veth1', 10, nil]
    ]
  ].each do |claim, first_identity, second_identity|
    it "rejects duplicate host-link #{claim} claims within a loaded manager" do
      stub_containers_registry([ct])
      claiming_class
      base_cfg = {
        'type' => 'test_manager_claim',
        'hwaddr' => nil,
        'max_tx' => 0,
        'max_rx' => 0,
        'enable' => true
      }

      expect do
        described_class.load(
          ct,
          [
            base_cfg.merge(
              'name' => 'eth0',
              'host_link_identity' => first_identity
            ),
            base_cfg.merge(
              'name' => 'eth1',
              'host_link_identity' => second_identity
            )
          ]
        )
      end.to raise_error(
        OsCtld::NetInterface::HostLinkClaimError,
        /also claimed by container tank:ct1/
      )
    end
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

  it 'does not discard an interface with a recorded host-link owner' do
    netif = managed_class.new(ct, 0)
    netif.create(name: 'eth0', hwaddr: nil)
    netif.define_singleton_method(:host_link_identity) { ['veth0', 10, nil] }
    manager = described_class.new(ct, entries: [netif])

    expect { manager.delete(netif) }.to raise_error(
      OsCtld::NetInterface::HostLinkClaimError,
      /complete lifecycle cleanup before removing/
    )

    expect(manager['eth0']).to be(netif)
    expect(ct.save_config_calls).to eq(0)
  end

  it 'rejects a conflicting host-link owner before publishing an interface' do
    netif = managed_class.new(ct, 0)
    netif.create(name: 'eth0', hwaddr: nil)
    netif.define_singleton_method(:host_link_identity) { ['veth0', 10, nil] }
    other_netif = instance_double(
      claiming_class,
      host_link_identity: ['veth2', 10, nil]
    )
    other_ct = FakeObjects::FakeRuntimeContainer.new(
      pool: ct.pool,
      id: 'ct2',
      netifs: [other_netif]
    )
    stub_containers_registry([ct, other_ct])
    manager = described_class.new(ct)

    expect { manager.add(netif) }.to raise_error(
      OsCtld::NetInterface::HostLinkClaimError,
      /also claimed by container tank:ct2/
    )

    expect(manager.contains?('eth0')).to be(false)
    expect(ct.save_config_calls).to eq(0)
  end

  it 'does not publish an added interface while the host-link registry is held' do
    holder_ready = Queue.new
    release_holder = Queue.new
    add_started = Queue.new
    netif = managed_class.new(ct, 0)
    netif.create(name: 'eth0', hwaddr: nil)
    manager = described_class.new(ct)

    holder = Thread.new do
      OsCtld::NetInterface.sync_host_link_registry do
        holder_ready << true
        release_holder.pop
      end
    end
    holder_ready.pop
    adder = Thread.new do
      add_started << true
      manager.add(netif)
    end
    add_started.pop

    expect(adder.join(0.05)).to be_nil
    expect(manager.contains?('eth0')).to be(false)

    release_holder << true
    holder.join
    adder.join

    expect(manager['eth0']).to be(netif)
  ensure
    release_holder << true if holder&.alive?
    holder&.join
    adder&.join
  end

  it 'does not remove an interface while the host-link registry is held' do
    holder_ready = Queue.new
    release_holder = Queue.new
    delete_started = Queue.new
    netif = managed_class.new(ct, 0)
    netif.create(name: 'eth0', hwaddr: nil)
    manager = described_class.new(ct, entries: [netif])

    holder = Thread.new do
      OsCtld::NetInterface.sync_host_link_registry do
        holder_ready << true
        release_holder.pop
      end
    end
    holder_ready.pop
    deleter = Thread.new do
      delete_started << true
      manager.delete(netif)
    end
    delete_started.pop

    expect(deleter.join(0.05)).to be_nil
    expect(manager['eth0']).to be(netif)

    release_holder << true
    holder.join
    deleter.join

    expect(manager.contains?('eth0')).to be(false)
  ensure
    release_holder << true if holder&.alive?
    holder&.join
    deleter&.join
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

  it 'owns the host-link registry without holding the manager lock during down' do
    created = managed_class.new(ct, 0)
    created.create(name: 'eth0', hwaddr: nil)
    created.created = true
    manager = described_class.new(ct, entries: [created])
    registry_owned = []
    allow(created).to receive(:down) do
      registry_owned << OsCtld::NetInterface::HOST_LINK_REGISTRY_LOCK.owned?
      manager.lock(:exclusive)
      manager.unlock(:exclusive)
    end

    manager.take_down

    expect(registry_owned).to eq([true])
  end
end
