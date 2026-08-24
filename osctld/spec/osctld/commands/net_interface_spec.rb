# frozen_string_literal: true

# rubocop:disable Lint/ConstantDefinitionInBlock, Lint/StructNewOverride, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/LeakyConstantDeclaration, RSpec/VerifiedDoubles

require 'osctld/command'
require 'osctld/exceptions'
require 'osctld/utils/switch_user'

module OsCtld
  module Commands
    module NetInterface; end
  end
end

require 'osctld/commands/net_interface/list'
require 'osctld/commands/net_interface/ip_list'
require 'osctld/commands/net_interface/route_list'
require 'osctld/commands/net_interface/create'
require 'osctld/commands/net_interface/delete'
require 'osctld/commands/net_interface/ip_add'
require 'osctld/commands/net_interface/ip_del'
require 'osctld/commands/net_interface/rename'
require 'osctld/commands/net_interface/route_add'
require 'osctld/commands/net_interface/route_del'
require 'osctld/commands/net_interface/set'
require 'osctld/commands/net_interface/show'

RSpec.describe 'net_interface commands' do
  IpAddr = Struct.new(:value) do
    def to_string
      value
    end
  end

  FakeRoutes = Struct.new(:hash) do
    def export
      hash
    end
  end

  class FakeNetifs
    include Enumerable

    def initialize(items)
      @items = items
    end

    def each(&block)
      @items.each(&block)
    end

    def map(&block)
      @items.map(&block)
    end

    def detect(&block)
      @items.detect(&block)
    end

    def [](name)
      @items.detect { |netif| netif.name == name }
    end

    def contains?(name)
      !self[name].nil?
    end

    def count
      @items.count
    end

    def <<(netif)
      @items << netif
    end

    def delete(netif)
      @items.delete(netif)
    end
  end

  def build_netif(name:, type:, link: nil, ips4: [], ips6: [], routes: {}, **attrs)
    Struct.new(
      :name, :index, :type, :link, :dhcp, :gateways, :veth, :hwaddr, :tx_queues,
      :rx_queues, :max_tx, :max_rx, :routes, :extra_ips,
      keyword_init: true
    ) do
      def ips(version)
        extra_ips.fetch(version, [])
      end

      def set(_changes); end

      def rename(new_name)
        self.name = new_name
      end

      def has_ip?(_addr, prefix: true)
        false
      end

      def add_ip(*); end

      def del_all_ips(*); end

      def add_route(*, **); end

      def del_all_routes(*); end
    end.new(
      name:,
      index: 0,
      type:,
      link:,
      dhcp: false,
      gateways: {},
      veth: nil,
      hwaddr: nil,
      tx_queues: nil,
      rx_queues: nil,
      max_tx: nil,
      max_rx: nil,
      routes: FakeRoutes.new(routes),
      extra_ips: { 4 => ips4.map { |ip| IpAddr.new(ip) }, 6 => ips6.map { |ip| IpAddr.new(ip) } }
    ).tap do |netif|
      attrs.each do |k, v|
        netif[k] = v if netif.members.include?(k)
      end
    end
  end

  def build_ct(id:, pool_name:, netifs:, runtime_state: :running)
    pool = Struct.new(:name).new(pool_name)
    lxc_config = Struct.new(:configured) do
      def configure_network
        self.configured = true
      end
    end.new(false)
    Struct.new(
      :id, :pool, :netifs, :runtime_state, :lxc_config, :saved,
      keyword_init: true
    ) do
      def inclusively
        yield
      end

      def manipulate(_holder, block:, &)
        yield
      end

      def save_config
        self.saved = true
      end

      def get_run_conf
        :run_conf
      end

      def can_dist_configure_network?
        true
      end
    end.new(
      id:,
      pool:,
      netifs: FakeNetifs.new(netifs),
      runtime_state:,
      lxc_config:,
      saved: false
    )
  end

  before do
    history = stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
    allow(history).to receive(:log)
    allow(OsCtl::Lib::Logger).to receive(:log)
    stub_const('OsCtld::DistConfig', Class.new do
      def self.run(*); end
    end)
    allow(OsCtld::DistConfig).to receive(:run)
  end

  describe OsCtld::Commands::NetInterface::List do
    it 'filters by pool, type, and bridge link while exporting interfaces' do
      bridge = build_netif(name: 'eth0', type: :bridge, link: 'br0')
      routed = build_netif(name: 'eth1', type: :routed)
      ct1 = build_ct(id: 'ct1', pool_name: 'tank', netifs: [bridge, routed])
      ct2 = build_ct(id: 'ct2', pool_name: 'pool2', netifs: [build_netif(name: 'eth0', type: :bridge, link: 'br0')])
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end

        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:get).and_return([ct1, ct2])

      ret = described_class.run(pool: 'tank', type: ['bridge'], link: ['br0'])

      expect(ret).to eq(
        status: true,
        output: [
          {
            name: 'eth0',
            index: 0,
            type: :bridge,
            link: 'br0',
            dhcp: false,
            gateways: {},
            veth: nil,
            hwaddr: nil,
            tx_queues: nil,
            rx_queues: nil,
            max_tx: nil,
            max_rx: nil,
            pool: 'tank',
            ctid: 'ct1'
          }
        ]
      )
    end
  end

  describe OsCtld::Commands::NetInterface::IpList do
    it 'lists IPs for interfaces in the selected pool' do
      bridge = build_netif(name: 'eth0', type: :bridge, ips4: ['192.0.2.10/24'], ips6: ['2001:db8::10/64'])
      ct = build_ct(id: 'ct1', pool_name: 'tank', netifs: [bridge])
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end

        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:get).and_return([ct])

      ret = described_class.run(pool: 'tank')

      expect(ret).to eq(
        status: true,
        output: [
          {
            pool: 'tank',
            ctid: 'ct1',
            netif: 'eth0',
            4 => ['192.0.2.10/24'],
            6 => ['2001:db8::10/64']
          }
        ]
      )
    end

    it 'rejects missing interfaces for a selected container' do
      ct = build_ct(id: 'ct1', pool_name: 'tank', netifs: [])
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect do
        described_class.run!(id: 'ct1', pool: 'tank', name: 'eth0')
      end.to raise_error(OsCtld::CommandFailed, 'network interface not found')
    end
  end

  describe OsCtld::Commands::NetInterface::RouteList do
    it 'lists routes only for routed interfaces in the selected pool' do
      routed = build_netif(name: 'eth1', type: :routed, routes: { 4 => ['192.0.2.0/24'], 6 => ['2001:db8::/64'] })
      bridge = build_netif(name: 'eth0', type: :bridge)
      ct = build_ct(id: 'ct1', pool_name: 'tank', netifs: [bridge, routed])
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end

        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:get).and_return([ct])

      ret = described_class.run(pool: 'tank')

      expect(ret).to eq(
        status: true,
        output: [
          {
            4 => ['192.0.2.0/24'],
            6 => ['2001:db8::/64'],
            pool: 'tank',
            ctid: 'ct1',
            netif: 'eth1'
          }
        ]
      )
    end

    it 'rejects non-routed interfaces when a specific netif is requested' do
      bridge = build_netif(name: 'eth0', type: :bridge)
      ct = build_ct(id: 'ct1', pool_name: 'tank', netifs: [bridge])
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect do
        described_class.run!(id: 'ct1', pool: 'tank', name: 'eth0')
      end.to raise_error(OsCtld::CommandFailed, 'not a routed interface')
    end
  end

  describe OsCtld::Commands::NetInterface::Set do
    before do
      history = stub_const('OsCtld::History', Class.new do
        def self.log(*); end
      end)
      allow(history).to receive(:log)
    end

    it 'rejects runtime changes for parameters that require a stopped container' do
      netif = build_netif(name: 'eth0', type: :bridge)
      ct = build_ct(
        id: 'ct1', pool_name: 'tank', netifs: [netif],
        runtime_state: :running
      )
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect do
        described_class.run!(id: 'ct1', pool: 'tank', name: 'eth0', link: 'br1')
      end.to raise_error(OsCtld::CommandFailed, 'the container must be stopped to change network interface')
    end

    it 'updates mutable attributes and persists network configuration' do
      netif = build_netif(name: 'eth0', type: :routed)
      ct = build_ct(
        id: 'ct1', pool_name: 'tank', netifs: [netif],
        runtime_state: :running
      )
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(netif).to receive(:set)

      ret = described_class.run(id: 'ct1', pool: 'tank', name: 'eth0', tx_queues: 4, max_rx: 10)

      expect(ret).to eq(status: true, output: nil)
      expect(netif).to have_received(:set).with(tx_queues: 4, max_rx: 10)
      expect(ct.saved).to be(true)
      expect(ct.lxc_config.configured).to be(true)
    end
  end

  describe OsCtld::Commands::NetInterface::Show do
    it 'exports the selected interface fields' do
      netif = build_netif(name: 'eth0', type: :bridge, link: 'br0')
      ct = build_ct(id: 'ct1', pool_name: 'tank', netifs: [netif])
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect(described_class.run(id: 'ct1', pool: 'tank', name: 'eth0')).to eq(
        status: true,
        output: {
          name: 'eth0',
          index: 0,
          type: :bridge,
          link: 'br0',
          dhcp: false,
          veth: nil
        }
      )
    end
  end

  describe OsCtld::Commands::NetInterface::Create do
    it 'creates a supported interface and regenerates usernet rules' do
      usernet = stub_const('OsCtld::Commands::User::LxcUsernet', Class.new)
      netif_class = Class.new do
        attr_reader :ct, :index, :name

        def initialize(ct, index)
          @ct = ct
          @index = index
        end

        def create(opts)
          @name = opts[:name]
        end

        def setup; end
      end
      stub_const('OsCtld::NetInterface', Class.new do
        def self.for(_type); end
      end)
      ct = build_ct(
        id: 'ct1', pool_name: 'tank', netifs: [],
        runtime_state: :stopped
      )
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(OsCtld::NetInterface).to receive(:for).with(:bridge).and_return(netif_class)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      command = described_class.new({ id: 'ct1', pool: 'tank', name: 'eth0', type: 'bridge' }, {})
      allow(command).to receive(:call_cmd).with(usernet).and_return(status: true, output: nil)

      expect(command.base_execute).to eq(status: true, output: nil)
      expect(ct.netifs['eth0']).not_to be_nil
      expect(OsCtld::DistConfig).to have_received(:run).with(:run_conf, :add_netif, netif: ct.netifs['eth0'])
    end
  end

  describe OsCtld::Commands::NetInterface::Delete do
    it 'deletes stopped interfaces and regenerates usernet rules' do
      usernet = stub_const('OsCtld::Commands::User::LxcUsernet', Class.new)
      netif = build_netif(name: 'eth0', type: :bridge)
      ct = build_ct(
        id: 'ct1', pool_name: 'tank', netifs: [netif],
        runtime_state: :stopped
      )
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      command = described_class.new({ id: 'ct1', pool: 'tank', name: 'eth0' }, {})
      allow(command).to receive(:call_cmd).with(usernet).and_return(status: true, output: nil)

      expect(command.base_execute).to eq(status: true, output: nil)
      expect(ct.netifs['eth0']).to be_nil
      expect(OsCtld::DistConfig).to have_received(:run).with(:run_conf, :remove_netif, netif:)
    end
  end

  describe OsCtld::Commands::NetInterface::Rename do
    it 'renames stopped interfaces and reconfigures network state' do
      netif = build_netif(name: 'eth0', type: :bridge)
      ct = build_ct(
        id: 'ct1', pool_name: 'tank', netifs: [netif],
        runtime_state: :stopped
      )
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(netif).to receive(:rename) do |new_name|
        netif.name = new_name
      end

      expect(described_class.run(id: 'ct1', pool: 'tank', old_name: 'eth0', new_name: 'eth1')).to eq(
        status: true,
        output: nil
      )
      expect(netif.name).to eq('eth1')
      expect(OsCtld::DistConfig).to have_received(:run).with(
        :run_conf,
        :rename_netif,
        netif:,
        original_name: 'eth0'
      )
    end
  end

  describe OsCtld::Commands::NetInterface::IpAdd do
    it 'adds routed IPs with explicit routes and persists network config' do
      netif = build_netif(name: 'eth0', type: :routed)
      ct = build_ct(id: 'ct1', pool_name: 'tank', netifs: [netif])
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(netif).to receive(:has_ip?).and_return(false)
      allow(netif).to receive(:add_ip)

      expect(
        described_class.run(
          id: 'ct1',
          pool: 'tank',
          name: 'eth0',
          addr: '192.0.2.10/24',
          route: '192.0.2.0/24'
        )
      ).to eq(status: true, output: nil)
      expect(netif).to have_received(:add_ip) do |addr, route|
        expect(addr.to_string).to eq('192.0.2.10/24')
        expect(route.to_string).to eq('192.0.2.0/24')
      end
      expect(OsCtld::DistConfig).to have_received(:run).with(:run_conf, :network)
    end
  end

  describe OsCtld::Commands::NetInterface::IpDel do
    it 'removes all IPs for routed interfaces with version filters' do
      netif = build_netif(name: 'eth0', type: :routed)
      ct = build_ct(id: 'ct1', pool_name: 'tank', netifs: [netif])
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(netif).to receive(:del_all_ips)

      expect(
        described_class.run(
          id: 'ct1',
          pool: 'tank',
          name: 'eth0',
          addr: 'all',
          version: '6',
          keep_route: true
        )
      ).to eq(status: true, output: nil)
      expect(netif).to have_received(:del_all_ips).with(6, true)
    end
  end

  describe OsCtld::Commands::NetInterface::RouteAdd do
    it 'adds routed entries when the via address exists on the interface' do
      routes = double('Routes', route?: false)
      netif = build_netif(name: 'eth0', type: :routed)
      allow(netif).to receive(:routes).and_return(routes)
      allow(netif).to receive(:has_ip?).with(IPAddress.parse('192.0.2.1'), prefix: false).and_return(true)
      allow(netif).to receive(:add_route)
      ct = build_ct(id: 'ct1', pool_name: 'tank', netifs: [netif])
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect(
        described_class.run(
          id: 'ct1',
          pool: 'tank',
          name: 'eth0',
          addr: '198.51.100.0/24',
          via: '192.0.2.1'
        )
      ).to eq(status: true, output: nil)
      expect(netif).to have_received(:add_route) do |addr, via:|
        expect(addr.to_string).to eq('198.51.100.0/24')
        expect(via.to_string).to eq('192.0.2.1/32')
      end
    end
  end

  describe OsCtld::Commands::NetInterface::RouteDel do
    it 'removes all routes for routed interfaces with version filters' do
      netif = build_netif(name: 'eth0', type: :routed)
      allow(netif).to receive(:del_all_routes)
      ct = build_ct(id: 'ct1', pool_name: 'tank', netifs: [netif])
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect(
        described_class.run(
          id: 'ct1',
          pool: 'tank',
          name: 'eth0',
          addr: 'all',
          version: '4'
        )
      ).to eq(status: true, output: nil)
      expect(netif).to have_received(:del_all_routes).with(4)
    end
  end
end

# rubocop:enable Lint/ConstantDefinitionInBlock, Lint/StructNewOverride, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/LeakyConstantDeclaration, RSpec/VerifiedDoubles
