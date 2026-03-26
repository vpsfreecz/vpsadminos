# frozen_string_literal: true

require 'osctld/routing/route'

RSpec.describe OsCtld::Routing::Route do
  it 'loads routes from strings and hashes' do
    string_route = described_class.load('192.0.2.1')
    hash_route = described_class.load('address' => '2001:db8::/64', 'via' => '2001:db8::1')

    expect(string_route.addr.to_string).to eq('192.0.2.1/32')
    expect(hash_route.addr.to_string).to eq('2001:db8::/64')
    expect(hash_route.via.to_s).to eq('2001:db8::1')
  end

  it 'matches exact routes and networks' do
    host_route = described_class.new(IPAddress.parse('192.0.2.10'))
    network_route = described_class.new(IPAddress.parse('192.0.2.0/24'))

    expect(host_route.route?(IPAddress.parse('192.0.2.10'))).to be(true)
    expect(network_route.route?(IPAddress.parse('192.0.2.20'))).to be(true)
    expect(network_route.route?(IPAddress.parse('198.51.100.1'))).to be(false)
  end

  it 'dumps, exports, and formats ip specs' do
    route = described_class.new(
      IPAddress.parse('2001:db8::/64'),
      via: IPAddress.parse('2001:db8::1')
    )

    expect(route.dump).to eq('address' => '2001:db8::/64', 'via' => '2001:db8::1')
    expect(route.export).to eq(address: route.addr, via: route.via)
    expect(route.ip_spec).to eq(['2001:db8::/64', 'via', '2001:db8::1', 'onlink'])
  end
end
