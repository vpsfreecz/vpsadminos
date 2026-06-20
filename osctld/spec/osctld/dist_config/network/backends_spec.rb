# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/VerifiedDoubles

require 'osctld/dist_config'
require 'osctld/erb_template'
require 'osctld/dist_config/network/ifupdown'
require 'osctld/dist_config/network/network_manager'
require 'osctld/dist_config/network/redhat_network_manager'
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
    File.write(File.join(rootfs, 'etc/sysconfig/network-scripts/ifcfg-lo'), 'DEVICE=lo')
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

  it 'does not use NetworkManager keyfiles when interface ifcfg files exist' do
    FileUtils.mkdir_p(File.join(rootfs, 'etc/sysconfig/network-scripts'))
    FileUtils.mkdir_p(File.join(rootfs, 'etc/NetworkManager/conf.d'))
    FileUtils.mkdir_p(File.join(rootfs, 'etc/NetworkManager/system-connections'))
    FileUtils.mkdir_p(File.join(rootfs, 'etc/systemd/system/multi-user.target.wants'))
    File.write(
      File.join(rootfs, 'etc/systemd/system/multi-user.target.wants/NetworkManager.service'),
      ''
    )
    File.write(File.join(rootfs, 'etc/sysconfig/network-scripts/ifcfg-eth0'), 'DEVICE=eth0')

    backend = OsCtld::DistConfig::Network::NetworkManager.new(configurator)

    expect(backend.usable?).to be(false)
  end

  it 'does not use NetworkManager keyfiles when ifcfg-rh is configured' do
    FileUtils.mkdir_p(File.join(rootfs, 'etc/sysconfig/network-scripts'))
    FileUtils.mkdir_p(File.join(rootfs, 'etc/NetworkManager/conf.d'))
    FileUtils.mkdir_p(File.join(rootfs, 'etc/NetworkManager/system-connections'))
    FileUtils.mkdir_p(File.join(rootfs, 'etc/systemd/system/multi-user.target.wants'))
    File.write(
      File.join(rootfs, 'etc/systemd/system/multi-user.target.wants/NetworkManager.service'),
      ''
    )
    File.write(File.join(rootfs, 'etc/sysconfig/network-scripts/ifcfg-lo'), 'DEVICE=lo')
    File.write(
      File.join(rootfs, 'etc/NetworkManager/conf.d/vpsadminos.conf'),
      "[main]\nplugins+=ifcfg-rh\n"
    )

    expect(OsCtld::DistConfig::Network::NetworkManager.new(configurator).usable?).to be(false)
    expect(OsCtld::DistConfig::Network::RedHatNetworkManager.new(configurator).usable?).to be(true)
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
