# frozen_string_literal: true

module OsCtld
  module Utils; end
end

require 'ipaddress'
require 'osctld/lock_registry'
require 'osctld/lockable'
require 'osctld/utils/ip'
require 'osctld/utils/switch_user'
require 'osctld/net_interface'
require 'osctld/net_interface/base'
require 'osctld/net_interface/veth'

RSpec.describe OsCtld::NetInterface::Veth do
  let(:root) { Dir.mktmpdir('osctld-veth') }
  let(:pool) { build_fake_pool(root:) }
  let(:ct) { FakeObjects::FakeRuntimeContainer.new(pool:, id: 'ct1', running: false) }
  let(:veth) { described_class.new(ct, 0) }

  before do
    allow(OsCtld::LockRegistry).to receive(:register)
    OsCtl::Lib::Logger.setup(:none)
    stub_const('OsCtld::Eventd', Module.new do
      def self.report(*); end
    end)
    allow(OsCtld::Eventd).to receive(:report)
    stub_const('OsCtld::ContainerControl', Module.new)
    stub_const('OsCtld::ContainerControl::Commands', Module.new)
    stub_const('OsCtld::ContainerControl::Commands::VethName', Class.new do
      def self.run!(*)
        'vethX'
      end
    end)
    allow(OsCtld::ContainerControl::Commands::VethName).to receive(:run!).and_return('vethX')
    hook_root = root
    OsCtld.define_singleton_method(:hook_src) { |name| File.join(hook_root, 'hooks-src', name) }
    FileUtils.mkdir_p(File.join(root, 'hooks-src'))
    allow(veth).to receive(:syscmd)
    allow(veth).to receive_messages(host_link_exists?: true, runtime_qdiscs: [], runtime_filters: [])
  end

  after do
    FileUtils.rm_rf(root)
  end

  it 'creates, saves, loads, and round-trips configured IPs' do
    veth.create(
      name: 'eth0',
      hwaddr: '00:11:22:33:44:55',
      tx_queues: 2,
      rx_queues: 3,
      max_tx: 100,
      max_rx: 200,
      enable: true
    )
    veth.add_ip(IPAddress.parse('192.0.2.10'))
    veth.add_ip(IPAddress.parse('2001:db8::10'))

    loaded = described_class.new(ct, 0)
    loaded.load(veth.save)

    expect(loaded.save).to eq(veth.save)
  end

  it 'creates hook symlinks and discovers the host veth when running' do
    ct.running = true
    veth.create(name: 'eth0', hwaddr: nil)

    veth.setup

    expect(File.symlink?(File.join(pool.hook_dir, 'veth', 'up', 'ct1.eth0'))).to be(true)
    expect(File.symlink?(File.join(pool.hook_dir, 'veth', 'down', 'ct1.eth0'))).to be(true)
    expect(veth.veth).to eq('vethX')
  end

  it 'discovers the existing host veth while the container is frozen' do
    ct.fresh_state = :frozen
    ct.state = :frozen
    veth.create(name: 'eth0', hwaddr: nil)

    veth.setup

    expect(veth.veth).to eq('vethX')
  end

  it 'observes a runtime discovered after interface setup' do
    veth.create(name: 'eth0', hwaddr: nil)
    veth.setup
    expect(veth.veth).to be_nil

    ct.running = true
    veth.observe_runtime

    expect(veth.veth).to eq('vethX')
  end

  it 'reports a missing required host veth for controlled recovery' do
    ct.running = true
    veth.create(name: 'eth0', hwaddr: nil, enable: true)
    allow(veth).to receive(:host_link_exists?).and_return(false)

    veth.setup

    expect(veth.veth).to be_nil
    expect(veth.reconcile_runtime).to include(
      status: 'missing',
      interface: 'eth0'
    )
  end

  it 'repairs missing transmit shaping during runtime reconciliation' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    allow(Dir).to receive(:exist?)
      .with('/sys/devices/virtual/net/ifbvethX')
      .and_return(true)

    expect(veth.reconcile_runtime).to include(status: 'healthy')

    expect(veth).to have_received(:syscmd).with(
      'tc filter replace dev vethX parent ffff: protocol all pref 10 handle 1 matchall action mirred egress redirect dev ifbvethX',
      {}
    )
  end

  it 'preserves unowned shaping when no limit is configured' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 0, max_rx: 0, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    allow(Dir).to receive(:exist?)
      .with('/sys/devices/virtual/net/ifbvethX')
      .and_return(true)
    allow(veth).to receive(:runtime_qdiscs).with('vethX').and_return(
      [
        { 'kind' => 'cake', 'root' => true },
        { 'kind' => 'ingress', 'handle' => 'ffff:' }
      ]
    )
    allow(veth).to receive(:runtime_filters).with('vethX').and_return(
      [
        {
          'kind' => 'matchall',
          'protocol' => 'all',
          'pref' => 49_152,
          'options' => { 'actions' => [{ 'to_dev' => 'ifbvethX' }] }
        }
      ]
    )

    expect(veth.reconcile_runtime).to include(status: 'healthy')

    expect(veth).not_to have_received(:syscmd).with(
      'tc qdisc delete root dev vethX',
      anything
    )
  end

  it 'blocks configured receive shaping on a foreign root qdisc' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 0, max_rx: 100, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    allow(veth).to receive(:runtime_qdiscs).with('vethX').and_return(
      [{ 'kind' => 'fq_codel', 'root' => true, 'handle' => '8001:' }]
    )

    expect(veth.reconcile_runtime).to include(
      status: 'error',
      error: /unowned receive qdisc/
    )
    expect(veth).not_to have_received(:syscmd).with(
      a_string_including('qdisc replace'),
      anything
    )
  end

  it 'replaces the kernel default qdisc with configured receive shaping' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 0, max_rx: 100, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    allow(veth).to receive(:runtime_qdiscs).with('vethX').and_return(
      [{ 'kind' => 'noqueue', 'root' => true, 'handle' => '0:' }]
    )

    expect(veth.reconcile_runtime).to include(status: 'healthy')
    expect(veth).to have_received(:syscmd).with(
      'tc qdisc replace dev vethX root handle 50c7: cake bandwidth 100bit',
      {}
    )
  end

  it 'claims exact legacy receive shaping only with handoff provenance' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 0, max_rx: 100, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    legacy = {
      'kind' => 'cake',
      'root' => true,
      'handle' => '8001:',
      'options' => { 'bandwidth' => 13 }
    }
    allow(veth).to receive(:runtime_qdiscs).with('vethX').and_return([legacy])

    expect(veth.reconcile_runtime).to include(
      status: 'error',
      error: /unowned receive qdisc/
    )
    expect(veth.reconcile_runtime(legacy_runtime: true)).to include(
      status: 'healthy'
    )
    expect(veth).to have_received(:syscmd).with(
      'tc qdisc replace dev vethX root handle 50c7: cake bandwidth 100bit',
      {}
    ).once
  end

  it 'preserves an exact legacy-shaped foreign transmit filter without provenance' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100, max_rx: 0, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    allow(Dir).to receive(:exist?)
      .with('/sys/devices/virtual/net/ifbvethX')
      .and_return(true)
    allow(veth).to receive(:runtime_qdiscs).with('vethX').and_return(
      [{ 'kind' => 'ingress', 'handle' => 'ffff:' }]
    )
    allow(veth).to receive(:runtime_qdiscs).with('ifbvethX').and_return(
      [
        {
          'kind' => 'cake',
          'root' => true,
          'handle' => '50c7:',
          'options' => { 'bandwidth' => 13, 'diffserv' => 'besteffort' }
        }
      ]
    )
    allow(veth).to receive(:runtime_filters).with('vethX').and_return(
      [
        {
          'kind' => 'matchall',
          'protocol' => 'all',
          'pref' => 49_152,
          'options' => {
            'handle' => 1,
            'actions' => [
              {
                'kind' => 'mirred',
                'mirred_action' => 'redirect',
                'direction' => 'egress',
                'to_dev' => 'ifbvethX'
              }
            ]
          }
        }
      ]
    )

    expect(veth.reconcile_runtime).to include(
      status: 'error',
      error: /unowned transmit filter/
    )
    expect(veth).not_to have_received(:syscmd).with(
      a_string_matching(/tc (?:qdisc|filter) (?:delete|replace)/),
      anything
    )
  end

  it 'claims exact legacy transmit shaping with handoff provenance' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100, max_rx: 0, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    allow(Dir).to receive(:exist?)
      .with('/sys/devices/virtual/net/ifbvethX')
      .and_return(true)
    allow(veth).to receive(:runtime_qdiscs).with('vethX').and_return(
      [{ 'kind' => 'ingress', 'handle' => 'ffff:' }]
    )
    allow(veth).to receive(:runtime_qdiscs).with('ifbvethX').and_return(
      [
        {
          'kind' => 'cake',
          'root' => true,
          'handle' => '8001:',
          'options' => { 'bandwidth' => 13, 'diffserv' => 'besteffort' }
        }
      ]
    )
    allow(veth).to receive(:runtime_filters).with('vethX').and_return(
      [
        {
          'kind' => 'matchall',
          'protocol' => 'all',
          'pref' => 49_152,
          'options' => {
            'handle' => 1,
            'actions' => [
              {
                'kind' => 'mirred',
                'mirred_action' => 'redirect',
                'direction' => 'egress',
                'to_dev' => 'ifbvethX'
              }
            ]
          }
        }
      ]
    )

    expect(veth.reconcile_runtime(legacy_runtime: true)).to include(
      status: 'healthy'
    )
    expect(veth).to have_received(:syscmd).with(
      'tc qdisc replace dev ifbvethX root handle 50c7: cake bandwidth 100bit besteffort',
      {}
    ).ordered
    expect(veth).to have_received(:syscmd).with(
      'tc filter delete dev vethX parent ffff: protocol all pref 49152 handle 1 matchall',
      valid_rcs: [2]
    ).ordered
    expect(veth).to have_received(:syscmd).with(
      'tc filter replace dev vethX parent ffff: protocol all pref 10 handle 1 matchall action mirred egress redirect dev ifbvethX',
      {}
    ).ordered
  end

  it 'does not claim a legacy-looking IFB without its redirect filter' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100, max_rx: 0, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    allow(Dir).to receive(:exist?)
      .with('/sys/devices/virtual/net/ifbvethX')
      .and_return(true)
    allow(veth).to receive(:runtime_qdiscs).with('vethX').and_return(
      [{ 'kind' => 'ingress', 'handle' => 'ffff:' }]
    )
    allow(veth).to receive(:runtime_qdiscs).with('ifbvethX').and_return(
      [
        {
          'kind' => 'cake',
          'root' => true,
          'handle' => '8001:',
          'options' => { 'bandwidth' => 13, 'diffserv' => 'besteffort' }
        }
      ]
    )
    allow(veth).to receive(:runtime_filters).with('vethX').and_return([])

    expect(veth.reconcile_runtime(legacy_runtime: true)).to include(
      status: 'error',
      error: /unowned transmit qdisc/
    )
    expect(veth).not_to have_received(:syscmd).with(
      a_string_matching(/tc (?:qdisc|filter) (?:delete|replace)/),
      anything
    )
  end

  it 'removes stale owned shaping when no limits are configured' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 0, max_rx: 0, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    allow(Dir).to receive(:exist?)
      .with('/sys/devices/virtual/net/ifbvethX')
      .and_return(true)
    allow(veth).to receive(:runtime_qdiscs).with('vethX').and_return(
      [
        { 'kind' => 'cake', 'root' => true, 'handle' => '50c7:' },
        { 'kind' => 'ingress', 'handle' => 'ffff:' }
      ]
    )
    allow(veth).to receive(:runtime_qdiscs).with('ifbvethX').and_return(
      [{ 'kind' => 'cake', 'root' => true, 'handle' => '50c7:' }]
    )
    allow(veth).to receive(:runtime_filters).with('vethX').and_return(
      [
        {
          'kind' => 'matchall',
          'protocol' => 'all',
          'pref' => 10,
          'options' => {
            'handle' => 1,
            'actions' => [
              {
                'kind' => 'mirred',
                'mirred_action' => 'redirect',
                'direction' => 'egress',
                'to_dev' => 'ifbvethX'
              }
            ]
          }
        }
      ]
    )

    expect(veth.reconcile_runtime).to include(status: 'healthy')

    expect(veth).to have_received(:syscmd).with(
      'tc qdisc delete root dev vethX',
      valid_rcs: [2]
    )
    expect(veth).to have_received(:syscmd).with(
      'tc filter delete dev vethX parent ffff: protocol all pref 10 handle 1 matchall',
      valid_rcs: [2]
    )
    expect(veth).to have_received(:syscmd).with(
      'tc qdisc delete dev vethX handle ffff: ingress',
      valid_rcs: [2]
    )
    expect(veth).to have_received(:syscmd).with(
      'ip link del ifbvethX',
      valid_rcs: [1]
    )
  end

  it 'does not replace healthy shaping during runtime reconciliation' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100, max_rx: 200, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    allow(Dir).to receive(:exist?)
      .with('/sys/devices/virtual/net/ifbvethX')
      .and_return(true)
    allow(veth).to receive(:runtime_qdiscs).with('vethX').and_return(
      [
        {
          'kind' => 'cake',
          'root' => true,
          'handle' => '50c7:',
          'options' => { 'bandwidth' => 25 }
        },
        { 'kind' => 'ingress', 'handle' => 'ffff:' }
      ]
    )
    allow(veth).to receive(:runtime_qdiscs).with('ifbvethX').and_return(
      [
        {
          'kind' => 'cake',
          'root' => true,
          'handle' => '50c7:',
          'options' => { 'bandwidth' => 13, 'diffserv' => 'besteffort' }
        }
      ]
    )
    allow(veth).to receive(:runtime_filters).with('vethX').and_return(
      [
        {
          'kind' => 'matchall',
          'protocol' => 'all',
          'pref' => 10,
          'options' => {
            'handle' => 1,
            'actions' => [
              {
                'kind' => 'mirred',
                'mirred_action' => 'redirect',
                'direction' => 'egress',
                'to_dev' => 'ifbvethX'
              }
            ]
          }
        }
      ]
    )

    expect(veth.reconcile_runtime).to include(status: 'healthy')

    expect(veth).not_to have_received(:syscmd).with(
      a_string_matching(/tc (?:qdisc|filter)/),
      anything
    )
  end

  it 'replaces a stale owned transmit filter without deleting the replacement' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    allow(Dir).to receive(:exist?)
      .with('/sys/devices/virtual/net/ifbvethX')
      .and_return(true)
    allow(veth).to receive(:runtime_qdiscs).with('vethX').and_return(
      [{ 'kind' => 'ingress', 'handle' => 'ffff:' }]
    )
    allow(veth).to receive(:runtime_qdiscs).with('ifbvethX').and_return(
      [
        {
          'kind' => 'cake',
          'root' => true,
          'handle' => '50c7:',
          'options' => { 'bandwidth' => 13, 'diffserv' => 'besteffort' }
        }
      ]
    )
    allow(veth).to receive(:runtime_filters).with('vethX').and_return(
      [
        {
          'kind' => 'matchall',
          'protocol' => 'all',
          'pref' => 10,
          'options' => { 'handle' => 1, 'actions' => [] }
        }
      ]
    )

    expect(veth.reconcile_runtime).to include(status: 'healthy')

    expect(veth).to have_received(:syscmd).with(
      'tc filter delete dev vethX parent ffff: protocol all pref 10 handle 1 matchall',
      valid_rcs: [2]
    ).ordered
    expect(veth).to have_received(:syscmd).with(
      'tc filter replace dev vethX parent ffff: protocol all pref 10 handle 1 matchall action mirred egress redirect dev ifbvethX',
      {}
    ).ordered
  end

  it 'removes an owned stale IFB even when its redirect filter is gone' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 0, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    allow(Dir).to receive(:exist?)
      .with('/sys/devices/virtual/net/ifbvethX')
      .and_return(true)
    allow(veth).to receive(:runtime_qdiscs).with('vethX').and_return(
      [{ 'kind' => 'ingress', 'handle' => 'ffff:' }]
    )
    allow(veth).to receive(:runtime_qdiscs).with('ifbvethX').and_return(
      [{ 'kind' => 'cake', 'root' => true, 'handle' => '50c7:' }]
    )
    allow(veth).to receive(:runtime_filters).with('vethX').and_return([])

    expect(veth.reconcile_runtime).to include(status: 'healthy')

    expect(veth).to have_received(:syscmd).with(
      'tc qdisc delete dev vethX handle ffff: ingress',
      valid_rcs: [2]
    )
    expect(veth).to have_received(:syscmd).with(
      'ip link del ifbvethX',
      valid_rcs: [1]
    )
  end

  it 'preserves foreign ingress filters while removing stale shaping' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 0, max_rx: 0, enable: true)
    veth.instance_variable_set(:@veth, 'vethX')
    allow(Dir).to receive(:exist?)
      .with('/sys/devices/virtual/net/ifbvethX')
      .and_return(true)
    allow(veth).to receive(:runtime_qdiscs).with('vethX').and_return(
      [{ 'kind' => 'ingress', 'handle' => 'ffff:' }]
    )
    allow(veth).to receive(:runtime_filters).with('vethX').and_return(
      [
        {
          'kind' => 'matchall',
          'pref' => 10,
          'options' => { 'actions' => [{ 'to_dev' => 'ifbvethX' }] }
        },
        { 'kind' => 'bpf', 'pref' => 20 }
      ]
    )

    expect(veth.reconcile_runtime).to include(status: 'healthy')

    expect(veth).not_to have_received(:syscmd).with(
      'tc qdisc delete dev vethX handle ffff: ingress',
      anything
    )
    expect(veth).not_to have_received(:syscmd).with(
      'ip link del ifbvethX',
      anything
    )
  end

  it 'renames hook symlinks and reports link state transitions' do
    veth.create(name: 'eth0', hwaddr: nil, enable: false)
    veth.setup

    veth.rename('eth1')
    veth.up('veth0')
    veth.down

    expect(File).not_to exist(File.join(pool.hook_dir, 'veth', 'up', 'ct1.eth0'))
    expect(File.symlink?(File.join(pool.hook_dir, 'veth', 'up', 'ct1.eth1'))).to be(true)
    expect(veth).to have_received(:syscmd).with('ip link set veth0 down', {})
    expect(veth).to have_received(:syscmd).with('ip link del veth0', {})
    expect(OsCtld::Eventd).to have_received(:report).with(
      :ct_netif,
      hash_including(action: :rename, name: 'eth0', new_name: 'eth1')
    )
    expect(OsCtld::Eventd).to have_received(:report).with(
      :ct_netif,
      hash_including(action: :up, veth: 'veth0')
    )
    expect(OsCtld::Eventd).to have_received(:report).with(
      :ct_netif,
      hash_including(action: :down, name: 'eth1')
    )
  end

  it 'tracks IPs, supports prefix-less lookup, and isolates duplicated state' do
    veth.create(name: 'eth0', hwaddr: nil)
    ipv4 = IPAddress.parse('192.0.2.10/24')
    ipv6 = IPAddress.parse('2001:db8::10/64')
    veth.add_ip(ipv4)
    veth.add_ip(ipv6)

    expect(veth.active_ip_versions).to eq([4, 6])
    expect(veth.has_ip?(IPAddress.parse('192.0.2.10/24'))).to be(true)
    expect(veth.has_ip?(IPAddress.parse('192.0.2.10'), prefix: false)).to be(true)

    copy = veth.dup(FakeObjects::FakeRuntimeContainer.new(pool:, id: 'ct2'))
    copy.add_ip(IPAddress.parse('192.0.2.11/24'))
    copy.del_ip(ipv4)
    copy.del_all_ips(6)

    expect(veth.ips(4).map(&:to_string)).to eq(['192.0.2.10/24'])
    expect(veth.ips(6).map(&:to_string)).to eq(['2001:db8::10/64'])
    expect(copy.veth).to be_nil
  end
end
