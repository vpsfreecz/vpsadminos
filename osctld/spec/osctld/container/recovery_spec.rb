# frozen_string_literal: true

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles

require 'osctld/container/recovery'

RSpec.describe OsCtld::Container::Recovery do
  let(:pool) { FakeObjects::FakePool.new(name: 'tank') }
  let(:route) { double(addr: double(to_string: '10.0.0.1/32')) }
  let(:routes) { double }
  let(:netif) { double(type: :routed, routes: routes, veth: 'veth0') }
  let(:ct) do
    double(
      pool: pool,
      id: 'ct1',
      ident: 'tank:ct1',
      netifs: [netif]
    )
  end
  let(:recovery) { described_class.new(ct) }

  before do
    stub_const(
      'OsCtld::DB::Containers',
      Class.new do
        def self.get; end
      end
    )
    allow(OsCtld::Container::Recovery::RouteList).to receive(:new).and_return(
      double(veth_of: 'veth0')
    )
    allow(recovery).to receive(:syscmd)
    allow(recovery).to receive(:log)
    allow(routes).to receive(:each_version) do |_ip_v, &block|
      block.call(route)
    end
  end

  it 'removes stale veths that only the recovered container references' do
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct])

    yielded = []
    recovery.cleanup_netifs do |veth, found_routes|
      yielded << [veth, found_routes]
    end

    expect(yielded).to eq([['veth0', [route, route]]])
    expect(recovery).to have_received(:syscmd).with('ip link delete veth0')
  end

  it 'keeps veths that another container still references' do
    other_netif = double(veth: 'veth0')
    other_ct = double(netifs: [other_netif], ident: 'tank:ct2')
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct, other_ct])

    recovery.cleanup_netifs

    expect(recovery).not_to have_received(:syscmd).with('ip link delete veth0')
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles
