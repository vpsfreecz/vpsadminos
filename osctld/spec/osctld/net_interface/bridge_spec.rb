# frozen_string_literal: true

module OsCtld
  module Utils; end
end

require 'ipaddress'
require 'socket'
require 'osctld/lock_registry'
require 'osctld/lockable'
require 'osctld/utils/ip'
require 'osctld/utils/switch_user'
require 'osctld/container'
require 'osctld/net_interface'
require 'osctld/net_interface/base'
require 'osctld/net_interface/veth'
require 'osctld/net_interface/bridge'

RSpec.describe OsCtld::NetInterface::Bridge do
  def running_container_with_lifecycle(pool, lifecycle)
    OsCtld::Container.allocate.tap do |ct|
      ct.send(:init_lock)
      ct.instance_variable_set(:@pool, pool)
      ct.instance_variable_set(:@id, 'ct1')
      ct.instance_variable_set(:@config_state, :ready)
      ct.instance_variable_set(:@runtime_state, :running)
      ct.instance_variable_set(:@lifecycle, lifecycle)
    end
  end

  def bridge_ifaddr(name, address, version)
    addr = Struct.new(:ip_address, :version) do
      def ip?
        true
      end

      def ipv4?
        version == 4
      end

      def ipv6?
        version == 6
      end
    end.new(address, version)

    Struct.new(:name, :addr).new(name, addr)
  end

  let(:root) { Dir.mktmpdir('osctld-bridge') }
  let(:pool) { build_fake_pool(root:) }
  let(:ct) { FakeObjects::FakeRuntimeContainer.new(pool:, id: 'ct1', running: true) }
  let(:bridge) { described_class.new(ct, 0) }

  before do
    allow(OsCtld::LockRegistry).to receive(:register)
    OsCtl::Lib::Logger.setup(:none)
    allow(bridge).to receive(:ct_syscmd)
    allow(bridge).to receive_messages(runtime_qdiscs: [], runtime_filters: [])
  end

  after do
    FileUtils.rm_rf(root)
  end

  it 'creates, loads, saves, and updates bridge attributes' do
    bridge.create(name: 'eth0', hwaddr: nil, link: 'br0', dhcp: false, gateways: { 4 => '192.0.2.1', 6 => 'none' })
    bridge.add_ip(IPAddress.parse('192.0.2.10/24'))

    loaded = described_class.new(ct, 0)
    loaded.load(bridge.save)
    loaded.set(link: 'br1', dhcp: true, gateways: { 6 => 'fe80::1' })

    expect(loaded.render_opts).to include(name: 'eth0', link: 'br1')
    expect(loaded.save['gateways']).to eq('v4' => '192.0.2.1', 'v6' => 'fe80::1')
  end

  it 'detects gateways from configuration and interface addresses' do
    bridge.create(name: 'eth0', hwaddr: nil, link: 'br0', gateways: { 4 => 'auto', 6 => 'none' })
    allow(Socket).to receive(:getifaddrs).and_return(
      [bridge_ifaddr('br0', '192.0.2.1', 4)]
    )

    expect(bridge.has_gateway?(4)).to be(true)
    expect(bridge.gateway(4)).to eq('192.0.2.1')
    expect(bridge.has_gateway?(6)).to be(false)
  end

  it 'configures container addresses only while running and isolates gateway state on dup' do
    bridge.create(name: 'eth0', hwaddr: nil, link: 'br0', gateways: { 4 => '192.0.2.1', 6 => 'none' })
    bridge.add_ip(IPAddress.parse('192.0.2.10/24'))
    bridge.del_ip(IPAddress.parse('192.0.2.10/24'))

    expect(bridge).to have_received(:ct_syscmd).with(
      ct,
      ['ip', '-4', 'addr', 'add', '192.0.2.10/24', 'dev', 'eth0'],
      valid_rcs: [2]
    )
    expect(bridge).to have_received(:ct_syscmd).with(
      ct,
      ['ip', '-4', 'addr', 'del', '192.0.2.10/24', 'dev', 'eth0'],
      valid_rcs: [2]
    )

    copy = bridge.dup(FakeObjects::FakeRuntimeContainer.new(pool:, id: 'ct2'))
    copy.set(gateways: { 4 => '192.0.2.254' })

    expect(bridge.gateway(4)).to eq('192.0.2.1')
    expect(copy.gateway(4)).to eq('192.0.2.254')
  end

  it 'runs container commands while the initialized lifecycle is read-locked' do
    lifecycle = Object.new
    running_ct = running_container_with_lifecycle(pool, lifecycle)
    interface = described_class.new(running_ct, 0)
    interface.create(
      name: 'eth0',
      hwaddr: nil,
      link: 'br0',
      gateways: { 4 => '192.0.2.1', 6 => 'none' }
    )
    allow(interface).to receive(:ct_syscmd) do |target, *|
      expect(target.lifecycle).to equal(lifecycle)
    end

    interface.add_ip(IPAddress.parse('192.0.2.10/24'))

    expect(interface).to have_received(:ct_syscmd).once
  end

  it 'reattaches a healthy host veth to its configured bridge' do
    bridge.create(name: 'eth0', hwaddr: nil, link: 'br0')
    bridge.instance_variable_set(:@veth, 'veth0')
    allow(bridge).to receive(:ip)

    expect(bridge.reconcile_runtime).to include(status: 'healthy')

    expect(bridge).to have_received(:ip).with(
      :all,
      %w[link set veth0 up]
    )
    expect(bridge).to have_received(:ip).with(
      :all,
      %w[link set veth0 master br0]
    )
  end
end
