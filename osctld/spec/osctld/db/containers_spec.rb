# frozen_string_literal: true

require 'osctld/db/containers'

RSpec.describe OsCtld::DB::Containers do
  let(:pool) { FakeObjects::FakeNamed.new('tank') }

  def build_container(id, netifs)
    OsCtld::DB::ContainersSpecObject.new(id:, pool:, netifs:)
  end

  before do
    stub_const(
      'OsCtld::DB::ContainersSpecObject',
      Struct.new(:id, :pool, :netifs, keyword_init: true) do
        def ident = "#{pool.name}:#{id}"
      end
    )
    stub_const(
      'OsCtld::DB::ContainersSpecNetif',
      Struct.new(:name, :host_link_identity, keyword_init: true)
    )

    eventd = stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)
    allow(eventd).to receive(:report)
    described_class.instance.instance_variable_set(:@objects, [])
  end

  after do
    described_class.instance.instance_variable_set(:@objects, [])
  end

  it 'rejects a conflicting container before publishing it' do
    first_netif = instance_double(
      OsCtld::DB::ContainersSpecNetif,
      name: 'eth0',
      host_link_identity: ['veth0', 10, nil]
    )
    second_netif = instance_double(
      OsCtld::DB::ContainersSpecNetif,
      name: 'eth0',
      host_link_identity: ['veth2', 10, nil]
    )
    first = build_container('ct1', [first_netif])
    second = build_container('ct2', [second_netif])

    described_class.add(first)

    expect { described_class.add(second) }.to raise_error(
      OsCtld::NetInterface::HostLinkClaimError,
      /also claimed by container tank:ct1/
    )

    expect(described_class.get).to eq([first])
  end

  it 'refuses to unpublish a container with retained host-link authority' do
    identity = ['veth0', 10, nil]
    netif = instance_double(OsCtld::DB::ContainersSpecNetif, name: 'eth0')
    allow(netif).to receive(:host_link_identity) { identity }
    ct = build_container('ct1', [netif])
    described_class.add(ct)

    expect { described_class.remove(ct) }.to raise_error(
      OsCtld::NetInterface::HostLinkClaimError,
      /still owns host links through network interface "eth0"/
    )
    expect(described_class.get).to eq([ct])

    identity = [nil, nil, nil]
    described_class.remove(ct)

    expect(described_class.get).to be_empty
  end
end
