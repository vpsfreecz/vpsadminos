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

  it 'only routes configured address families on split dual-stack interfaces' do
    routed = [4, 6].map do |version|
      build_netif(
        name: "eth#{version}",
        type: :routed,
        ips_by_version: {
          version => [IPAddress.parse(version == 4 ? '192.0.2.10/32' : '2001:db8::10/128')]
        },
        gateways: {},
        default_via_by_version: { 4 => '255.255.255.254', 6 => 'fe80::1' }
      )
    end

    cfg = described_class.create(Struct.new(:netifs).new(routed))

    expect(cfg.netifs.map { |netif| netif.routes.map(&:version) }).to eq([[4, 4], [6, 6]])
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
        handler.define_singleton_method(:clear_cache) { nil }
        handler.define_singleton_method(:list) do |**|
          [Struct.new(:address, :flags).new(IPAddr.new('2001:db8::10'), 0)]
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

  describe 'IPv6 readiness' do
    let(:cfg) do
      described_class.import([{ name: 'eth1', ips: [{ version: 6, address: '2001:db8::10', prefix: 128 }], routes: [] }])
    end
    let(:addr) { instance_double(Linux::Netlink::Route::AddrHandler) }
    let(:nl) { Struct.new(:addr).new(addr) }

    before do
      allow(addr).to receive(:clear_cache)
      allow(cfg).to receive(:sleep)
    end

    def snapshot(flags)
      [Struct.new(:address, :flags).new(IPAddr.new('2001:db8::10'), flags)]
    end

    it 'refreshes tentative addresses until duplicate address detection completes' do
      allow(addr).to receive(:list).with(index: 'eth1', family: Socket::AF_INET6)
                                   .and_return(snapshot(Linux::IFA_F_TENTATIVE), snapshot(0))

      cfg.send(:wait_for_ipv6_addresses, nl)

      expect(addr).to have_received(:clear_cache).twice
      expect(cfg).to have_received(:sleep).with(0.1).once
    end

    it 'rejects an address that fails duplicate address detection' do
      allow(addr).to receive(:list).and_return(snapshot(Linux::IFA_F_DADFAILED))

      expect { cfg.send(:wait_for_ipv6_addresses, nl) }
        .to raise_error(RuntimeError, /duplicate address detection failed: eth1=2001:db8::10/)
    end

    it 'also waits for the automatic link-local address used by neighbor discovery' do
      tentative = snapshot(0) + [Struct.new(:address, :flags).new(IPAddr.new('fe80::1'), Linux::IFA_F_TENTATIVE)]
      ready = snapshot(0) + [Struct.new(:address, :flags).new(IPAddr.new('fe80::1'), 0)]
      allow(addr).to receive(:list).and_return(tentative, ready)

      cfg.send(:wait_for_ipv6_addresses, nl)

      expect(addr).to have_received(:clear_cache).twice
      expect(cfg).to have_received(:sleep).with(0.1).once
    end

    %i[missing tentative].each do |state|
      it "bounds waiting for #{state} addresses" do
        allow(addr).to receive(:list).and_return(state == :tentative ? snapshot(Linux::IFA_F_TENTATIVE) : [])

        expect { cfg.send(:wait_for_ipv6_addresses, nl, timeout: 0) }
          .to raise_error(RuntimeError, /IPv6 addresses not ready: eth1=2001:db8::10/)
      end
    end

    it 'does not query addresses for an IPv4-only config' do
      cfg.netifs.first.ips.clear

      cfg.send(:wait_for_ipv6_addresses, nl)

      expect(addr).not_to have_received(:clear_cache)
    end
  end
end
