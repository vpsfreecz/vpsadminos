# frozen_string_literal: true

require 'osctld/utils/ip'

RSpec.describe OsCtld::Utils::Ip do
  let(:link_handler) { instance_double(Linux::Netlink::Route::LinkHandler) }
  let(:live_link) do
    instance_double(
      Linux::Netlink::IFInfo,
      index: 42,
      ifname: 'veth0',
      kind: 'veth'
    )
  end
  let(:netlink_socket) do
    instance_double(Linux::Netlink::Route::Socket, link: link_handler)
  end
  let(:host) do
    Class.new do
      include OsCtld::Utils::Ip

      attr_reader :calls

      def initialize
        @calls = []
      end

      def syscmd_argv(cmd, opts)
        calls << [cmd, opts]
        :ok
      end
    end.new
  end

  before do
    allow(Linux::Netlink::Route::Socket).to receive(:open).and_yield(netlink_socket)
    allow(link_handler).to receive(:[]).with(42).and_return(live_link)
    allow(netlink_socket).to receive(:cmd)
  end

  it 'builds ip commands for the requested protocol family' do
    expect(host.ip(4, %w[addr show], valid_rcs: [0])).to eq(:ok)
    expect(host.ip(6, %w[route show], valid_rcs: [0])).to eq(:ok)
    expect(host.tc(%w[qdisc show], valid_rcs: [0])).to eq(:ok)

    expect(host.calls).to eq(
      [
        [%w[ip -4 addr show], { valid_rcs: [0] }],
        [%w[ip -6 route show], { valid_rcs: [0] }],
        [%w[tc qdisc show], { valid_rcs: [0] }]
      ]
    )
  end

  it 'normalizes symbolic ip and tc arguments for argv execution' do
    expect(host.ip(:all, [:link, :show, :dev, 'osrtr0'])).to eq(:ok)
    expect(host.tc([:qdisc, :show, :dev, 'veth0'])).to eq(:ok)

    expect(host.calls).to eq(
      [
        [%w[ip link show dev osrtr0], {}],
        [%w[tc qdisc show dev veth0], {}]
      ]
    )
  end

  it 'validates the recorded index and deletes atomically by its reserved name' do
    host.delete_link_by_ifindex(
      42,
      expected_name: 'veth0',
      expected_kind: 'veth'
    )

    expect(Linux::Netlink::Route::Socket).to have_received(:open)
    expect(link_handler).to have_received(:[]).with(42)
    expect(netlink_socket).to have_received(:cmd) do |type, message|
      expect(type).to eq(Linux::RTM_DELLINK)
      expect(message.index).to eq(0)
      expect(message.ifname).to eq('veth0')
    end
  end

  it 'resolves a positive ifindex only for the expected name and kind' do
    allow(link_handler).to receive(:[]).with('veth0').and_return(live_link)

    expect(
      host.link_ifindex_by_name(
        expected_name: 'veth0',
        expected_kind: 'veth'
      )
    ).to eq(42)

    expect(link_handler).to have_received(:[]).with('veth0')
  end

  it 'rejects a callback name whose live link has another kind' do
    allow(link_handler).to receive(:[]).with('veth0').and_return(live_link)
    allow(live_link).to receive(:kind).and_return('bridge')

    expect do
      host.link_ifindex_by_name(
        expected_name: 'veth0',
        expected_kind: 'veth'
      )
    end.to raise_error(
      described_class::LinkIdentityError,
      /kind "veth".*kind "bridge"/
    )
  end

  it 'distinguishes an absent named link from a mismatched live identity' do
    allow(link_handler).to receive(:[]).with('veth0').and_return(nil)

    expect do
      host.link_ifindex_by_name(
        expected_name: 'veth0',
        expected_kind: 'veth'
      )
    end.to raise_error(
      described_class::LinkNotFound,
      /kind "veth".*is absent/
    )
  end

  it 'rejects an absent recorded index without sending a delete' do
    allow(link_handler).to receive(:[]).with(42).and_raise(KeyError)

    expect do
      host.delete_link_by_ifindex(
        42,
        expected_name: 'veth0',
        expected_kind: 'veth'
      )
    end.to raise_error(
      described_class::LinkIdentityError,
      /ifindex 42.*is absent/
    )

    expect(netlink_socket).not_to have_received(:cmd)
  end

  it 'rejects a nil link lookup without sending a delete' do
    allow(link_handler).to receive(:[]).with(42).and_return(nil)

    expect do
      host.delete_link_by_ifindex(
        42,
        expected_name: 'veth0',
        expected_kind: 'veth'
      )
    end.to raise_error(
      described_class::LinkIdentityError,
      /ifindex 42.*is absent/
    )

    expect(netlink_socket).not_to have_received(:cmd)
  end

  it 'rejects an index reassigned to a different name or link kind' do
    allow(live_link).to receive_messages(ifname: 'foreign0', kind: 'ifb')

    expect do
      host.delete_link_by_ifindex(
        42,
        expected_name: 'veth0',
        expected_kind: 'veth'
      )
    end.to raise_error(
      described_class::LinkIdentityError,
      /is now "foreign0".*kind "ifb"/
    )

    expect(netlink_socket).not_to have_received(:cmd)
  end

  it 'rejects link names and non-positive ifindexes' do
    ['veth0', 0, -1].each do |invalid_ifindex|
      expect do
        host.delete_link_by_ifindex(
          invalid_ifindex,
          expected_name: 'veth0',
          expected_kind: 'veth'
        )
      end.to raise_error(ArgumentError, /invalid network interface index/)
    end

    expect(Linux::Netlink::Route::Socket).not_to have_received(:open)
  end
end
