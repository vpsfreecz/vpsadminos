# frozen_string_literal: true

require 'ipaddress'
require 'osctld/lock_registry'
require 'osctld/lockable'
require 'osctld/net_interface'
require 'osctld/net_interface/base'

RSpec.describe OsCtld::NetInterface::Base do
  let(:ct) { FakeObjects::FakeRuntimeContainer.new(pool: Struct.new(:name).new('tank'), id: 'ct1') }
  let(:klass) do
    Class.new(described_class) do
      type :test_base
      attr_writer :created

      def initialize(*)
        super
        @ips = { 4 => [], 6 => [] }
        @created = false
      end

      def render_opts
        { name:, index: }
      end

      def is_created?
        @created
      end

      def ips(v)
        @ips[v]
      end

      def add_ip(addr)
        @ips[addr.ipv4? ? 4 : 6] << addr
      end

      def del_ip(addr)
        @ips[addr.ipv4? ? 4 : 6].delete(addr)
      end
    end
  end
  let(:netif) { klass.new(ct, 0) }

  before do
    allow(OsCtld::LockRegistry).to receive(:register)
    stub_const('OsCtld::Eventd', Module.new do
      def self.report(*); end
    end)
    allow(OsCtld::Eventd).to receive(:report)
  end

  it 'creates, loads, saves, renames, and updates base attributes' do
    netif.create(name: 'eth0', hwaddr: '00:11:22:33:44:55', max_tx: 100, max_rx: 200, enable: true)
    netif.rename('eth1')
    netif.set(hwaddr: '00:11:22:33:44:66', max_tx: 300, max_rx: 400, enable: false)

    expect(netif.save).to eq(
      'type' => 'test_base',
      'name' => 'eth1',
      'hwaddr' => '00:11:22:33:44:66',
      'max_tx' => 300,
      'max_rx' => 400,
      'enable' => false
    )
    expect(OsCtld::Eventd).to have_received(:report).with(
      :ct_netif,
      action: :rename,
      pool: 'tank',
      id: 'ct1',
      name: 'eth0',
      new_name: 'eth1'
    )

    loaded = klass.new(ct, 1)
    loaded.load(netif.save)
    expect(loaded.save).to eq(netif.save)
  end

  it 'checks IP membership, link state, and distconfig eligibility' do
    netif.create(name: 'eth0', hwaddr: nil)
    netif.add_ip(IPAddress.parse('192.0.2.10'))
    netif.created = true

    expect(netif.has_ip?(IPAddress.parse('192.0.2.10'))).to be(true)
    expect(netif.is_up?).to be(true)
    expect(netif.can_run_distconfig?).to be(true)

    netif.set(enable: false)
    expect(netif.is_up?).to be(false)
  end
end
