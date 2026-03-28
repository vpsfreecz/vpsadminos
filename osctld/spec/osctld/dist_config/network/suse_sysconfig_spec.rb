# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubles

require 'ostruct'

require 'osctld/dist_config'
require 'osctld/dist_config/configurator'
require 'osctld/dist_config/network/suse_sysconfig'
require 'osctld/erb_template'

RSpec.describe OsCtld::DistConfig::Network::SuseSysconfig do
  let(:rootfs) { Dir.mktmpdir('suse-rootfs') }
  let(:configurator) do
    double(
      ctid: 'pool:ct1',
      rootfs: rootfs,
      distribution: 'opensuse',
      version: '15.6'
    )
  end
  let(:backend) { described_class.new(configurator) }
  let(:netif) do
    double(
      name: 'eth1',
      type: :routed,
      active_ip_versions: [4],
      ips: [],
      routes: []
    )
  end

  before do
    FileUtils.mkdir_p(File.join(rootfs, 'etc/sysconfig/network'))
    FileUtils.mkdir_p(File.join(rootfs, 'etc/wicked'))
    allow(OsCtld::ErbTemplate).to receive(:render_to_if_changed)
  end

  after do
    FileUtils.rm_rf(rootfs)
  end

  it 'is usable when wicked directories are present' do
    expect(backend.usable?).to be(true)
  end

  it 'removes both ifcfg and ifroute files' do
    File.write(File.join(rootfs, 'etc/sysconfig/network', 'ifcfg-eth0'), 'cfg')
    File.write(File.join(rootfs, 'etc/sysconfig/network', 'ifroute-eth0'), 'route')

    backend.remove_netif([], double(name: 'eth0'))

    expect(File.exist?(File.join(rootfs, 'etc/sysconfig/network', 'ifcfg-eth0'))).to be(false)
    expect(File.exist?(File.join(rootfs, 'etc/sysconfig/network', 'ifroute-eth0'))).to be(false)
  end

  it 'removes stale files before writing renamed interface config' do
    File.write(File.join(rootfs, 'etc/sysconfig/network', 'ifcfg-eth0'), 'cfg')
    File.write(File.join(rootfs, 'etc/sysconfig/network', 'ifroute-eth0'), 'route')

    backend.rename_netif([], netif, 'eth0')

    expect(File.exist?(File.join(rootfs, 'etc/sysconfig/network', 'ifcfg-eth0'))).to be(false)
    expect(File.exist?(File.join(rootfs, 'etc/sysconfig/network', 'ifroute-eth0'))).to be(false)
    expect(OsCtld::ErbTemplate).to have_received(:render_to_if_changed).twice
  end
end
# rubocop:enable RSpec/VerifiedDoubles
