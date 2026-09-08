# frozen_string_literal: true

require 'ipaddress'
require 'osctld/net_config'

RSpec.describe OsCtld::NetConfig do
  def build_netif(name:, type:, ips_by_version:, gateways:, default_via_by_version:)
    Struct.new(:name, :type, :ips_by_version, :gateways, :default_via_by_version, keyword_init: true) do
      def ips(version)
        ips_by_version.fetch(version, [])
      end

      def has_gateway?(version)
        gateways.has_key?(version)
      end

      def gateway(version)
        gateways.fetch(version)
      end

      def default_via(version)
        default_via_by_version.fetch(version)
      end
    end.new(
      name:,
      type:,
      ips_by_version:,
      gateways:,
      default_via_by_version:
    )
  end

  it 'creates configs from container netifs and round-trips export/import' do
    bridge = build_netif(
      name: 'eth0',
      type: :bridge,
      ips_by_version: { 4 => [IPAddress.parse('192.0.2.10/24')] },
      gateways: { 4 => '192.0.2.1', 6 => 'fe80::1' },
      default_via_by_version: {}
    )
    routed = build_netif(
      name: 'eth1',
      type: :routed,
      ips_by_version: { 6 => [IPAddress.parse('2001:db8::10/64')] },
      gateways: {},
      default_via_by_version: { 4 => IPAddress.parse('255.255.255.254/32'), 6 => IPAddress.parse('fe80::1') }
    )
    ct = Struct.new(:netifs).new([bridge, routed])

    cfg = described_class.create(ct)
    restored = described_class.import(cfg.export)

    expect(restored.export).to eq(cfg.export)
    expect(cfg.export.first[:routes]).to include(
      { version: 4, address: '0.0.0.0', prefix: 0, via: '192.0.2.1' },
      { version: 6, address: '::', prefix: 0, via: 'fe80::1' }
    )
    expect(cfg.export.last[:routes]).to include(
      { version: 6, address: '::', prefix: 0, via: 'fe80::1' }
    )
  end

  it 'applies addresses and routes through netlink and ignores EEXIST' do
    addr_calls = []
    route_calls = []
    socket = Struct.new(:addr, :route, :link).new(
      Object.new.tap do |handler|
        handler.define_singleton_method(:add) do |**kwargs|
          raise Errno::EEXIST if kwargs[:local] == '192.0.2.10'

          addr_calls << kwargs
        end
      end,
      Object.new.tap do |handler|
        handler.define_singleton_method(:add) do |**kwargs|
          raise Errno::EEXIST if kwargs[:dst] == '0.0.0.0'

          route_calls << kwargs
        end
      end,
      Object.new.tap do |handler|
        handler.define_singleton_method(:list) do
          [Struct.new(:ifname).new('eth0')]
        end
      end
    )
    allow(Linux::Netlink::Route::Socket).to receive(:new).and_return(socket)

    cfg = described_class.import(
      [
        {
          name: 'eth0',
          ips: [
            { version: 4, address: '192.0.2.10', prefix: 24 },
            { version: 6, address: '2001:db8::10', prefix: 64 }
          ],
          routes: [
            { version: 4, address: '0.0.0.0', prefix: 0, via: '192.0.2.1' },
            { version: 6, address: '::', prefix: 0, via: 'fe80::1' }
          ]
        }
      ]
    )

    cfg.setup

    expect(addr_calls).to eq([{ index: 'eth0', local: '2001:db8::10', prefixlen: 64 }])
    expect(route_calls).to eq([{ oif: 'eth0', dst: '::', dst_len: 0, gateway: 'fe80::1' }])
  end

  it 'waits for network interfaces to appear before applying config' do
    addr_calls = []
    route_calls = []
    link_calls = 0
    socket = Struct.new(:addr, :route, :link).new(
      Object.new.tap do |handler|
        handler.define_singleton_method(:add) { |**kwargs| addr_calls << kwargs }
      end,
      Object.new.tap do |handler|
        handler.define_singleton_method(:add) { |**kwargs| route_calls << kwargs }
      end,
      Object.new.tap do |handler|
        handler.define_singleton_method(:list) do
          link_calls += 1
          next [] if link_calls == 1

          [Struct.new(:ifname).new('eth0')]
        end
      end
    )
    allow(Linux::Netlink::Route::Socket).to receive(:new).and_return(socket)

    cfg = described_class.import(
      [
        {
          name: 'eth0',
          ips: [
            { version: 4, address: '192.0.2.10', prefix: 24 }
          ],
          routes: []
        }
      ]
    )

    cfg.setup

    expect(link_calls).to eq(2)
    expect(addr_calls).to eq([{ index: 'eth0', local: '192.0.2.10', prefixlen: 24 }])
    expect(route_calls).to eq([])
  end
end
