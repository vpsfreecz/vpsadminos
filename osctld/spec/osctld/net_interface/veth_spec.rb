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
