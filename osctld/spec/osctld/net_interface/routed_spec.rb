# frozen_string_literal: true

module OsCtld
  module Utils; end
end

require 'ipaddress'
require 'socket'
require 'osctld/exceptions'
require 'osctld/lock_registry'
require 'osctld/lockable'
require 'osctld/utils/ip'
require 'osctld/utils/switch_user'
require 'osctld/container'
require 'osctld/net_interface'
require 'osctld/net_interface/base'
require 'osctld/net_interface/veth'
require 'osctld/net_interface/routed'
require 'osctld/routing/route'
require 'osctld/routing/table'

RSpec.describe OsCtld::NetInterface::Routed do
  def running_container_with_lifecycle(pool, lifecycle)
    OsCtld::Container.allocate.tap do |ct|
      ct.send(:init_lock)
      ct.instance_variable_set(:@pool, pool)
      ct.instance_variable_set(:@id, 'ct1')
      ct.instance_variable_set(:@state, :running)
      ct.instance_variable_set(:@lifecycle, lifecycle)
    end
  end

  def routed_ifaddr(name, address)
    addr = Struct.new(:ip_address) do
      def ip?
        true
      end

      def ipv6?
        true
      end
    end.new(address)

    Struct.new(:name, :addr).new(name, addr)
  end

  let(:root) { Dir.mktmpdir('osctld-routed') }
  let(:pool) { build_fake_pool(root:) }
  let(:ct) { FakeObjects::FakeRuntimeContainer.new(pool:, id: 'ct1', running: true) }
  let(:routed) { described_class.new(ct, 0) }

  before do
    allow(OsCtld::LockRegistry).to receive(:register)
    OsCtl::Lib::Logger.setup(:none)
    stub_const('OsCtld::ContainerControl', Module.new)
    stub_const('OsCtld::ContainerControl::Commands', Module.new)
    stub_const('OsCtld::ContainerControl::Commands::VethName', Class.new do
      def self.run!(*)
        'veth0'
      end
    end)
    allow(OsCtld::ContainerControl::Commands::VethName).to receive(:run!).and_return('veth0')
    stub_const('OsCtld::Eventd', Module.new do
      def self.report(*); end
    end)
    allow(OsCtld::Eventd).to receive(:report)
    hook_root = root
    OsCtld.define_singleton_method(:hook_src) { |name| File.join(hook_root, 'hooks-src', name) }
    FileUtils.mkdir_p(File.join(root, 'hooks-src'))
    allow(routed).to receive(:ip)
    allow(routed).to receive(:ct_syscmd)
    allow(routed).to receive_messages(host_link_exists?: true, runtime_routes: [])
    allow(File).to receive(:write).and_return(1)
  end

  after do
    FileUtils.rm_rf(root)
  end

  it 'sets up the shared routed interface when missing' do
    allow(described_class).to receive(:ip).and_raise(
      OsCtld::SystemCommandFailed.new('ip link show', 1, '')
    )
    allow(described_class).to receive(:ip).with(:all, [:link, :show, :dev, described_class::INTERFACE]).and_raise(
      OsCtld::SystemCommandFailed.new('ip link show', 1, '')
    )
    allow(described_class).to receive(:ip).with(:all, [:link, :add, described_class::INTERFACE, :type, :dummy])
    allow(described_class).to receive(:ip).with(4, [:addr, :add, described_class::DEFAULT_IPV4.to_string, :dev, described_class::INTERFACE])

    described_class.setup

    expect(described_class).to have_received(:ip).with(:all, [:link, :add, 'osrtr0', :type, :dummy])
    expect(described_class).to have_received(:ip).with(4, [:addr, :add, '255.255.255.254/32', :dev, 'osrtr0'])
  end

  it 'creates, loads, saves, and updates routed routes' do
    routed.create(name: 'eth0', hwaddr: nil)
    routed.add_route(IPAddress.parse('192.0.2.0/24'))

    loaded = described_class.new(ct, 0)
    loaded.load(routed.save)
    loaded.set(enable: false)

    expect(loaded.save['routes']).to eq('v4' => ['192.0.2.0/24'], 'v6' => [])
  end

  it 'drops stale host veths during setup and reports distconfig readiness' do
    routed.create(name: 'eth0', hwaddr: nil)
    allow(routed).to receive_messages(
      fetch_veth_name: 'veth0',
      host_link_exists?: false
    )

    routed.setup

    expect(routed.veth).to be_nil
    expect(routed.can_run_distconfig?).to be(false)
  end

  it 'brings routes up, configures addresses, and manages route tables' do
    routed.create(name: 'eth0', hwaddr: nil)
    routed.add_route(IPAddress.parse('192.0.2.0/24'))
    allow(Socket).to receive(:getifaddrs).and_return(
      [routed_ifaddr('veth0', 'fe80::1%veth0')]
    )

    routed.up('veth0')
    routed.add_ip(IPAddress.parse('192.0.2.10/24'), IPAddress.parse('192.0.2.0/24'))
    routed.add_route(IPAddress.parse('2001:db8::/64'), via: IPAddress.parse('2001:db8::1'))
    routed.del_route(IPAddress.parse('2001:db8::/64'))
    routed.del_all_routes

    expect(routed).to have_received(:ip).with(
      4,
      %i[route add] + ['192.0.2.0/24'] + \
        [:protocol, 'osctld', :dev, 'veth0']
    ).at_least(:once)
    expect(routed).to have_received(:ct_syscmd).with(
      ct,
      ['ip', '-4', 'addr', 'add', '192.0.2.10/24', 'dev', 'eth0'],
      valid_rcs: [2]
    )
    expect(routed.default_via(4).to_string).to eq('255.255.255.254/32')
    expect(routed.default_via(6).to_s).to eq('fe80::1')
    expect(routed.has_route?(IPAddress.parse('192.0.2.0/24'))).to be(false)
  end

  it 'runs container commands while the initialized lifecycle is read-locked' do
    lifecycle = Object.new
    running_ct = running_container_with_lifecycle(pool, lifecycle)
    interface = described_class.new(running_ct, 0)
    interface.create(name: 'eth0', hwaddr: nil)
    allow(interface).to receive(:ip)
    allow(interface).to receive(:ct_syscmd) do |target, *|
      expect(target.lifecycle).to equal(lifecycle)
    end

    interface.add_ip(IPAddress.parse('192.0.2.10/24'), nil)

    expect(interface).to have_received(:ct_syscmd).exactly(3).times
  end

  it 'repairs missing configured routes and restores reverse-path filtering' do
    routed.create(name: 'eth0', hwaddr: nil, enable: true)
    routed.instance_variable_set(:@veth, 'veth0')
    routed.routes.add(IPAddress.parse('192.0.2.0/24'))

    expect(routed.reconcile_runtime).to include(status: 'healthy')

    expect(routed).to have_received(:ip).with(
      4,
      %i[route add] + ['192.0.2.0/24'] + \
        [:protocol, 'osctld', :dev, 'veth0']
    )
    expect(File).to have_received(:write).with(
      '/proc/sys/net/ipv4/conf/veth0/rp_filter',
      '1'
    )
  end

  it 'removes only owned routes when the interface is disabled' do
    routed.create(name: 'eth0', hwaddr: nil, enable: false)
    routed.instance_variable_set(:@veth, 'veth0')
    routed.add_route(IPAddress.parse('192.0.2.0/24'))
    allow(routed).to receive(:runtime_routes).with(4).and_return(
      [
        { 'dst' => '192.0.2.0/24', 'dev' => 'veth0', 'protocol' => 'osctld' },
        { 'dst' => '198.51.100.0/24', 'dev' => 'veth0' }
      ]
    )
    allow(routed).to receive(:runtime_routes).with(6).and_return(
      [{ 'dst' => 'fe80::/64', 'dev' => 'veth0', 'protocol' => 'kernel' }]
    )

    expect(routed.reconcile_runtime).to include(status: 'healthy')

    expect(routed).to have_received(:ip).with(
      4,
      %i[route del] + ['192.0.2.0/24'] + \
        [:protocol, 'osctld', :dev, 'veth0']
    )
    expect(routed).not_to have_received(:ip).with(
      4,
      array_including('198.51.100.0/24')
    )
    expect(routed).not_to have_received(:ip).with(
      6,
      array_including('fe80::/64')
    )
  end

  it 'removes a mismatched owned route when the interface is disabled' do
    routed.create(name: 'eth0', hwaddr: nil, enable: false)
    routed.instance_variable_set(:@veth, 'veth0')
    routed.routes.add(
      IPAddress.parse('2001:db8::/64'),
      via: IPAddress.parse('fe80::1')
    )
    allow(routed).to receive(:runtime_routes).with(4).and_return([])
    allow(routed).to receive(:runtime_routes).with(6).and_return(
      [
        {
          'dst' => '2001:db8::/64',
          'gateway' => 'fe80::2',
          'dev' => 'veth0',
          'protocol' => 'osctld'
        },
        {
          'dst' => '2001:db8::/64',
          'gateway' => 'fe80::3',
          'dev' => 'veth0',
          'protocol' => 'static'
        }
      ]
    )

    expect(routed.reconcile_runtime).to include(status: 'healthy')

    expect(routed).to have_received(:ip).with(
      6,
      %i[route del] + ['2001:db8::/64'] + \
        [:via, 'fe80::2', :onlink, :protocol, 'osctld', :dev, 'veth0']
    )
    expect(routed).not_to have_received(:ip).with(
      6,
      array_including('fe80::3')
    )
  end

  it 'claims an exact legacy route without disturbing unrelated routes' do
    routed.create(name: 'eth0', hwaddr: nil, enable: true)
    routed.instance_variable_set(:@veth, 'veth0')
    routed.routes.add(IPAddress.parse('192.0.2.0/24'))
    allow(routed).to receive(:runtime_routes).with(4).and_return(
      [
        { 'dst' => '192.0.2.0/24', 'dev' => 'veth0', 'protocol' => 'boot' },
        { 'dst' => '198.51.100.0/24', 'dev' => 'veth0', 'protocol' => 'static' }
      ]
    )
    allow(routed).to receive(:runtime_routes).with(6).and_return([])

    expect(routed.reconcile_runtime).to include(status: 'healthy')

    expect(routed).to have_received(:ip).with(
      4,
      %i[route replace] + ['192.0.2.0/24'] + \
        [:protocol, 'osctld', :dev, 'veth0']
    )
    expect(routed).not_to have_received(:ip).with(
      4,
      %i[route del] + ['198.51.100.0/24'] + \
        [:protocol, 'osctld', :dev, 'veth0']
    )
  end

  it 'blocks on an exact foreign route instead of claiming it' do
    routed.create(name: 'eth0', hwaddr: nil, enable: true)
    routed.instance_variable_set(:@veth, 'veth0')
    routed.routes.add(IPAddress.parse('192.0.2.0/24'))
    allow(routed).to receive(:runtime_routes).with(4).and_return(
      [
        { 'dst' => '192.0.2.0/24', 'dev' => 'veth0', 'protocol' => 'static' }
      ]
    )
    allow(routed).to receive(:runtime_routes).with(6).and_return([])

    expect(routed.reconcile_runtime).to include(
      status: 'error',
      error: include('conflicts with unowned state')
    )

    expect(routed).not_to have_received(:ip).with(
      4,
      %i[route add] + ['192.0.2.0/24'] + \
        [:protocol, 'osctld', :dev, 'veth0']
    )
    expect(routed).not_to have_received(:ip).with(
      4,
      %i[route replace] + ['192.0.2.0/24'] + \
        [:protocol, 'osctld', :dev, 'veth0']
    )
  end

  it 'blocks on a conflicting legacy route with the same destination' do
    routed.create(name: 'eth0', hwaddr: nil, enable: true)
    routed.instance_variable_set(:@veth, 'veth0')
    routed.routes.add(
      IPAddress.parse('2001:db8::/64'),
      via: IPAddress.parse('fe80::1')
    )
    allow(routed).to receive(:runtime_routes).with(4).and_return([])
    allow(routed).to receive(:runtime_routes).with(6).and_return(
      [
        {
          'dst' => '2001:db8::/64',
          'gateway' => 'fe80::2',
          'dev' => 'veth0',
          'protocol' => 'boot'
        }
      ]
    )

    expect(routed.reconcile_runtime).to include(
      status: 'error',
      error: include('conflicts with unowned state')
    )

    expect(routed).not_to have_received(:ip).with(
      6,
      array_including(:replace, '2001:db8::/64')
    )
  end

  it 'blocks on a foreign route beside an exact owned route' do
    routed.create(name: 'eth0', hwaddr: nil, enable: true)
    routed.instance_variable_set(:@veth, 'veth0')
    routed.routes.add(IPAddress.parse('192.0.2.0/24'))
    allow(routed).to receive(:runtime_routes).with(4).and_return(
      [
        {
          'dst' => '192.0.2.0/24',
          'dev' => 'veth0',
          'protocol' => 'osctld'
        },
        {
          'dst' => '192.0.2.0/24',
          'gateway' => '192.0.2.1',
          'dev' => 'veth0',
          'protocol' => 'static'
        }
      ]
    )
    allow(routed).to receive(:runtime_routes).with(6).and_return([])

    expect(routed.reconcile_runtime).to include(
      status: 'error',
      error: include('conflicts with unowned state')
    )

    expect(routed).not_to have_received(:ip).with(
      4,
      array_including(:replace, '192.0.2.0/24')
    )
  end

  it 'blocks on a legacy route beside an exact owned route' do
    routed.create(name: 'eth0', hwaddr: nil, enable: true)
    routed.instance_variable_set(:@veth, 'veth0')
    routed.routes.add(IPAddress.parse('192.0.2.0/24'))
    allow(routed).to receive(:runtime_routes).with(4).and_return(
      [
        {
          'dst' => '192.0.2.0/24',
          'dev' => 'veth0',
          'protocol' => 'osctld'
        },
        {
          'dst' => '192.0.2.0/24',
          'gateway' => '192.0.2.1',
          'dev' => 'veth0',
          'protocol' => 'boot'
        }
      ]
    )
    allow(routed).to receive(:runtime_routes).with(6).and_return([])

    expect(routed.reconcile_runtime).to include(
      status: 'error',
      error: include('conflicts with unowned state')
    )

    expect(routed).not_to have_received(:ip).with(
      4,
      array_including(:replace, '192.0.2.0/24')
    )
  end

  it 'does not replace a healthy configured route' do
    routed.create(name: 'eth0', hwaddr: nil, enable: true)
    routed.instance_variable_set(:@veth, 'veth0')
    routed.routes.add(
      IPAddress.parse('2001:db8::/64'),
      via: IPAddress.parse('fe80::1')
    )
    allow(routed).to receive(:runtime_routes).with(4).and_return([])
    allow(routed).to receive(:runtime_routes).with(6).and_return(
      [
        {
          'dst' => '2001:db8::/64',
          'gateway' => 'fe80::1',
          'dev' => 'veth0',
          'protocol' => 'osctld'
        }
      ]
    )

    expect(routed.reconcile_runtime).to include(status: 'healthy')

    expect(routed).not_to have_received(:ip).with(
      6,
      array_including(:replace)
    )
  end

  it 'recognizes numeric protocol output and removes stale owned routes' do
    routed.create(name: 'eth0', hwaddr: nil, enable: true)
    routed.instance_variable_set(:@veth, 'veth0')
    routed.routes.add(IPAddress.parse('192.0.2.0/24'))
    allow(routed).to receive(:runtime_routes).with(4).and_return(
      [
        {
          'dst' => '192.0.2.0/24',
          'dev' => 'veth0',
          'protocol' => 230
        },
        {
          'dst' => '198.51.100.0/24',
          'dev' => 'veth0',
          'protocol' => '230'
        }
      ]
    )
    allow(routed).to receive(:runtime_routes).with(6).and_return([])

    expect(routed.reconcile_runtime).to include(status: 'healthy')

    expect(routed).not_to have_received(:ip).with(
      4,
      array_including(:replace, '192.0.2.0/24')
    )
    expect(routed).to have_received(:ip).with(
      4,
      %i[route del] + ['198.51.100.0/24'] + \
        [:protocol, 'osctld', :dev, 'veth0']
    )
  end

  it 'removes addresses, clears routes, and isolates duplicated route tables' do
    routed.create(name: 'eth0', hwaddr: nil)
    routed.instance_variable_set('@veth', 'veth0')
    routed.add_ip(IPAddress.parse('192.0.2.10/24'), IPAddress.parse('192.0.2.0/24'))
    routed.add_route(IPAddress.parse('192.0.2.11/32'))

    routed.del_ip(IPAddress.parse('192.0.2.10/24'), false)
    copy = routed.dup(FakeObjects::FakeRuntimeContainer.new(pool:, id: 'ct2'))
    copy.add_route(IPAddress.parse('192.0.2.12/32'))
    copy.del_all_ips(nil, true)

    expect(routed.has_route?(IPAddress.parse('192.0.2.11/32'))).to be(true)
    expect(copy.has_route?(IPAddress.parse('192.0.2.12/32'))).to be(true)
    expect(routed.has_route?(IPAddress.parse('192.0.2.12/32'))).to be(false)
  end
end
