# frozen_string_literal: true

require 'libosctl'
require 'osctld/lock_registry'
require 'osctld/lockable'
require 'osctld/routing/route'
require 'osctld/routing/table'

RSpec.describe OsCtld::Routing::Table do
  subject(:table) { described_class.new }

  before do
    allow(OsCtld::LockRegistry).to receive(:register)
  end

  let(:ipv4_host) { IPAddress.parse('192.0.2.10') }
  let(:ipv4_network) { IPAddress.parse('192.0.2.0/24') }
  let(:ipv6_host) { IPAddress.parse('2001:db8::10') }

  it 'adds and removes ipv4 and ipv6 routes' do
    route4 = table.add(ipv4_host)
    route6 = table.add(ipv6_host)

    expect(table.remove(ipv4_host)).to eq(route4)
    expect(table.remove(ipv6_host)).to eq(route6)
    expect(table.empty?(4)).to be(true)
    expect(table.empty?(6)).to be(true)
  end

  it 'checks routed and exact addresses' do
    table.add(ipv4_network)

    expect(table.route?(IPAddress.parse('192.0.2.20'))).to be(true)
    expect(table.contains?(ipv4_network)).to be(true)
    expect(table.contains?(IPAddress.parse('192.0.2.20'))).to be(false)
  end

  it 'removes all routes for one version or all versions' do
    table.add(ipv4_host)
    table.add(ipv6_host)

    expect(table.remove_all(4).map(&:addr)).to eq([ipv4_host])
    expect(table.any?(4)).to be(false)
    expect(table.any?(6)).to be(true)

    expect(table.remove_all.map(&:addr)).to eq([ipv6_host])
    expect(table.any?(6)).to be(false)
  end

  it 'iterates routes per ip version and removes routes conditionally' do
    table.add(ipv4_host)
    table.add(IPAddress.parse('192.0.2.11'))

    seen = []
    table.each_version(4) { |route| seen << route.addr.to_string }
    table.remove_version_if(4) { |route| route.addr.to_string == '192.0.2.10/32' }

    expect(seen).to eq(%w[192.0.2.10/32 192.0.2.11/32])
    expect(table.dump.fetch('v4')).to eq(['192.0.2.11/32'])
  end

  it 'exports and round-trips dump/load' do
    table.add(IPAddress.parse('192.0.2.0/24'))
    table.add(IPAddress.parse('2001:db8::/64'), via: IPAddress.parse('2001:db8::1'))

    dump = table.dump
    loaded = described_class.load(dump)

    expect(table.export).to eq(
      4 => [{ address: IPAddress.parse('192.0.2.0/24'), via: nil }],
      6 => [{ address: IPAddress.parse('2001:db8::/64'), via: IPAddress.parse('2001:db8::1') }]
    )
    expect(loaded.dump).to eq(dump)
  end
end
