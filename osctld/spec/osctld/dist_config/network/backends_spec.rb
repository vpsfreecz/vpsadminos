# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/VerifiedDoubles

require 'osctld/dist_config'
require 'osctld/erb_template'
require 'osctld/erb_template_cache'
require 'osctld/dist_config/network/ifupdown'
require 'osctld/dist_config/network/network_manager'
require 'osctld/dist_config/network/systemd_networkd'

RSpec.describe 'DistConfig network backends' do
  let(:rootfs) { Dir.mktmpdir('dist-network-rootfs') }
  let(:configurator) do
    double(
      ctid: 'tank:ct1',
      rootfs: rootfs,
      distribution: 'debian',
      version: '12'
    )
  end

  before do
    allow(OsCtld::ErbTemplate).to receive(:render_to_if_changed)
  end

  after do
    FileUtils.rm_rf(rootfs)
  end

  it 'detects and renders ifupdown configurations' do
    FileUtils.mkdir_p(File.join(rootfs, 'etc/network/interfaces.d'))
    File.write(File.join(rootfs, 'etc/network/interfaces'), "auto lo\n")
    File.write(File.join(rootfs, 'etc/network/interfaces.head'), "# head\n")
    File.write(File.join(rootfs, 'etc/network/interfaces.tail'), "# tail\n")

    backend = OsCtld::DistConfig::Network::Ifupdown.new(configurator)

    expect(backend.usable?).to be(true)

    backend.configure([double(name: 'eth0')])

    expect(OsCtld::ErbTemplate).to have_received(:render_to_if_changed).with(
      'dist_config/network/ifupdown/interfaces',
      include(
        interfacesd: true,
        head: "# head\n",
        tail: "# tail\n"
      ),
      File.join(rootfs, 'etc/network/interfaces')
    )
  end

  it 'uses NetworkManager when the service layout is enabled and regenerates config on removal' do
    FileUtils.mkdir_p(File.join(rootfs, 'etc/sysconfig/network-scripts'))
    FileUtils.mkdir_p(File.join(rootfs, 'etc/NetworkManager/conf.d'))
    FileUtils.mkdir_p(File.join(rootfs, 'etc/NetworkManager/system-connections'))
    FileUtils.mkdir_p(File.join(rootfs, 'etc/systemd/system/multi-user.target.wants'))
    FileUtils.mkdir_p(File.join(rootfs, 'etc/udev/rules.d'))
    File.write(
      File.join(rootfs, 'etc/systemd/system/multi-user.target.wants/NetworkManager.service'),
      ''
    )
    File.write(
      File.join(rootfs, 'etc/NetworkManager/system-connections/eth0.nmconnection'),
      'existing'
    )

    backend = OsCtld::DistConfig::Network::NetworkManager.new(configurator)

    expect(backend.usable?).to be(true)

    backend.remove_netif([double(name: 'eth1')], double(name: 'eth0'))

    expect(File.exist?(File.join(rootfs, 'etc/NetworkManager/system-connections/eth0.nmconnection'))).to be(false)
    expect(OsCtld::ErbTemplate).to have_received(:render_to_if_changed).with(
      'dist_config/network/network_manager/nm_conf',
      anything,
      File.join(rootfs, 'etc/NetworkManager/conf.d/osctl.conf')
    )
    expect(OsCtld::ErbTemplate).to have_received(:render_to_if_changed).with(
      'dist_config/network/network_manager/udev_rules',
      anything,
      File.join(rootfs, 'etc/udev/rules.d/86-osctl.rules')
    )
  end

  [true, false].each do |with_gateway|
    it "renders bridge addresses and configured gateways for networkd (gateway=#{with_gateway})" do
      template_path = File.expand_path('../../../../templates/dist_config/network/systemd_networkd/bridge.erb', __dir__)
      template = ERB.new(File.read(template_path), trim_mode: '-')
      allow(OsCtld::ErbTemplateCache).to receive(:[])
        .with('dist_config/network/systemd_networkd/bridge').and_return(template)
      allow(OsCtld::ErbTemplate).to receive(:render_to_if_changed).and_call_original
      FileUtils.mkdir_p(File.join(rootfs, 'etc/systemd/network'))
      netif = double(name: 'eth0', type: :bridge, dhcp: false, active_ip_versions: [4, 6])
      allow(netif).to receive(:ips).with(4).and_return([double(to_string: '192.0.2.2/24')])
      allow(netif).to receive(:ips).with(6).and_return([double(to_string: '2001:db8::2/64')])
      allow(netif).to receive(:has_gateway?).and_return(with_gateway)
      allow(netif).to receive(:gateway).with(4).and_return('192.0.2.1')
      allow(netif).to receive(:gateway).with(6).and_return('2001:db8::1')

      OsCtld::DistConfig::Network::SystemdNetworkd.new(configurator).configure([netif])

      rendered = File.read(File.join(rootfs, 'etc/systemd/network/eth0.network'))
      expect(rendered).to include("Address=192.0.2.2/24\n", "Address=2001:db8::2/64\n")
      if with_gateway
        expect(rendered).to include("Gateway=192.0.2.1\n", "Gateway=2001:db8::1\n")
      else
        expect(rendered).not_to include('Gateway=')
      end
    end
  end

  it 'renames systemd-networkd configs by removing the old file and rendering the new one' do
    FileUtils.mkdir_p(File.join(rootfs, 'etc/systemd/network'))
    FileUtils.mkdir_p(File.join(rootfs, 'etc/systemd/system/multi-user.target.wants'))
    File.write(
      File.join(rootfs, 'etc/systemd/system/multi-user.target.wants/systemd-networkd.service'),
      ''
    )
    File.write(File.join(rootfs, 'etc/systemd/network/eth0.network'), 'old')

    backend = OsCtld::DistConfig::Network::SystemdNetworkd.new(configurator)

    expect(backend.usable?).to be(true)

    backend.rename_netif([], double(name: 'eth1', type: :bridge), 'eth0')

    expect(File.exist?(File.join(rootfs, 'etc/systemd/network/eth0.network'))).to be(false)
    expect(OsCtld::ErbTemplate).to have_received(:render_to_if_changed).with(
      'dist_config/network/systemd_networkd/bridge',
      include(netif: have_attributes(name: 'eth1', type: :bridge)),
      File.join(rootfs, 'etc/systemd/network/eth1.network')
    )
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/VerifiedDoubles
