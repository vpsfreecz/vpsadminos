# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/VerifiedDoubles

require 'osctld/utils/switch_user'
require 'osctld/dist_config'
require 'osctld/erb_template'
require 'osctld/dist_config/distributions/base'
require 'osctld/dist_config/distributions/other'
require 'osctld/dist_config/distributions/debian'
require 'osctld/dist_config/distributions/ubuntu'
require 'osctld/dist_config/distributions/redhat'
require 'osctld/dist_config/distributions/nixos'
require 'osctld/dist_config/distributions/void'

RSpec.describe 'DistConfig distributions' do
  let(:hostname_class) { Struct.new(:local, :fqdn, keyword_init: true) }

  before do
    OsCtl::Lib::Logger.setup(:none)
  end

  it 'passes the legacy mounted root path to both NixOS post-mount helpers' do
    ct = double('Container', impermanence: true)
    ctrc = double('RunConfig', ct:, distribution: 'nixos', version: '24.05')
    distro = OsCtld::DistConfig::Distributions::NixOS.new(ctrc)
    allow(OsCtld::ContainerControl::Commands::WithMountns).to receive(:run!)

    distro.post_mount(ns_pid: 123, rootfs_mount: '/var/lib/lxc/ct1/rootfs')

    expect(OsCtld::ContainerControl::Commands::WithMountns).to have_received(:run!).with(
      ct,
      hash_including(ns_pid: 123, chroot: '/var/lib/lxc/ct1/rootfs')
    ).twice
  end

  it 'registers distribution families and aliases' do
    expect(OsCtld::DistConfig.for(:debian)).to eq(OsCtld::DistConfig::Distributions::Debian)
    expect(OsCtld::DistConfig.for(:ubuntu)).to eq(OsCtld::DistConfig::Distributions::Ubuntu)
    expect(OsCtld::DistConfig.for(:other)).to eq(OsCtld::DistConfig::Distributions::Other)
    expect(OsCtld::DistConfig::Distributions::Ubuntu < OsCtld::DistConfig::Distributions::Debian).to be(true)
  end

  it 'resolves distribution configurator classes' do
    ctrc = double(ct: double(id: 'ct1'), distribution: 'debian', version: '12')
    debian = OsCtld::DistConfig::Distributions::Debian.new(ctrc)
    other = OsCtld::DistConfig::Distributions::Other.new(
      double(ct: double(id: 'ct1'), distribution: 'mystery', version: '1')
    )

    expect(debian.configurator_class).to eq(OsCtld::DistConfig::Distributions::Debian::Configurator)
    expect(other.configurator_class).to eq(OsCtld::DistConfig::Configurator)
  end

  it 'does not configure guest files at start without hostname, DNS, or network changes' do
    ct = double(
      id: 'ct1',
      distribution: 'debian',
      version: '12',
      hostname: nil,
      dns_resolvers: nil
    )
    ctrc = double(
      ct:,
      distribution: 'debian',
      version: '12',
      dist_configure_network?: false
    )
    dist = OsCtld::DistConfig::Distributions::Debian.new(ctrc)
    allow(dist).to receive(:with_rootfs)

    dist.start

    expect(dist).not_to have_received(:with_rootfs)
  end

  describe 'live resolver application' do
    let(:ct) { double(id: 'ct1', dns_resolvers: ['1.1.1.1'], running?: true) }
    let(:configurator) { instance_double(OsCtld::DistConfig::Configurator) }
    let(:dist) do
      OsCtld::DistConfig::Distributions::Debian.new(
        double(ct:, distribution: 'debian', version: '12')
      )
    end

    before do
      dist.instance_variable_set(:@configurator, configurator)
      allow(dist).to receive(:with_rootfs).and_yield
      allow(dist).to receive(:ct_syscmd)
    end

    it 'applies NetworkManager policy before publishing the requested resolver file' do
      events = []
      allow(configurator).to receive(:prepare_dns_resolvers) do
        events << :prepare
        true
      end
      allow(dist).to receive(:ct_syscmd) { events << :reload }
      allow(configurator).to receive(:write_dns_resolvers).with(['8.8.8.8']) { events << :write }

      dist.dns_resolvers(resolvers: ['8.8.8.8'])

      expect(events).to eq(%i[prepare reload write])
      expect(dist).to have_received(:ct_syscmd)
        .with(ct, %w[nmcli general reload conf,dns-rc], valid_rcs: [0, 8])
    end

    it 'does not publish new resolver contents when the live reload fails' do
      allow(configurator).to receive(:prepare_dns_resolvers).and_return(true)
      allow(configurator).to receive(:write_dns_resolvers)
      allow(dist).to receive(:ct_syscmd).and_raise('reload failed')

      expect { dist.dns_resolvers }.to raise_error(RuntimeError, 'reload failed')
      expect(configurator).not_to have_received(:write_dns_resolvers)
    end

    it 'reloads DNS after unsetting the owned NetworkManager policy' do
      allow(configurator).to receive(:unset_dns_resolvers).and_return(true)

      dist.unset_dns_resolvers

      expect(dist).to have_received(:ct_syscmd)
        .with(ct, %w[nmcli general reload conf,dns-rc], valid_rcs: [0, 8])
    end

    it 'does not reload custom or absent NetworkManager installations' do
      allow(configurator).to receive_messages(prepare_dns_resolvers: false, unset_dns_resolvers: false)
      allow(configurator).to receive(:write_dns_resolvers)

      dist.dns_resolvers
      dist.unset_dns_resolvers

      expect(dist).not_to have_received(:ct_syscmd)
    end

    it 'only prepares files for a stopped container' do
      allow(ct).to receive(:running?).and_return(false)
      allow(configurator).to receive(:dns_resolvers).with(['1.1.1.1'])
      allow(configurator).to receive(:unset_dns_resolvers).and_return(true)

      dist.dns_resolvers
      dist.unset_dns_resolvers

      expect(configurator).to have_received(:dns_resolvers)
      expect(dist).not_to have_received(:ct_syscmd)
    end

    it 'keeps live NixOS resolver writes independent of a guest updater' do
      nixos = OsCtld::DistConfig::Distributions::NixOS.new(
        double(ct:, distribution: 'nixos', version: '22.11')
      )
      allow(ct).to receive(:impermanence).and_return(nil)
      nixos.instance_variable_set(:@configurator, configurator)
      allow(nixos).to receive(:with_rootfs).and_yield
      allow(nixos).to receive(:ct_syscmd)
      allow(configurator).to receive_messages(prepare_dns_resolvers: false, unset_dns_resolvers: false)
      allow(configurator).to receive(:write_dns_resolvers).with(['8.8.8.8'])

      nixos.dns_resolvers(resolvers: ['8.8.8.8'])
      nixos.unset_dns_resolvers

      expect(configurator).to have_received(:write_dns_resolvers).with(['8.8.8.8'])
      expect(nixos).not_to have_received(:ct_syscmd)
    end

    it 'never attaches from the pre-init rootfs helper' do
      dist.instance_variable_set(:@within_rootfs, true)
      allow(configurator).to receive(:dns_resolvers).with(['1.1.1.1'])

      dist.dns_resolvers

      expect(configurator).to have_received(:dns_resolvers)
      expect(ct).not_to have_received(:running?)
      expect(dist).not_to have_received(:ct_syscmd)
    end
  end

  it 'logs warnings for unsupported operations on Other' do
    ct = double
    dist = OsCtld::DistConfig::Distributions::Other.new(double(ct: ct, distribution: 'mystery', version: '1'))
    allow(dist).to receive(:log)

    dist.set_hostname
    dist.network

    expect(dist).to have_received(:log).with(:warn, ct, 'Unable to set hostname: mystery not supported')
    expect(dist).to have_received(:log).with(:warn, ct, 'Unable to configure network: mystery not supported')
  end

  it 'writes NixOS add and del network scripts through its dedicated configurator' do
    with_tmpdir do |rootfs|
      allow(OsCtld::ErbTemplate).to receive(:render).and_return('network command')
      config = OsCtld::DistConfig::Distributions::NixOS::Configurator.new('tank:ct1', rootfs, 'nixos', '24.11')

      config.network([double(type: :routed)])

      expect(config.send(:network_class)).to be_nil
      expect(File.read(File.join(rootfs, 'ifcfg.add'))).to eq('network command')
      expect(File.read(File.join(rootfs, 'ifcfg.del'))).to eq('network command')
    end
  end

  it 'writes Void hostname files and uses dedicated network handling' do
    with_tmpdir do |rootfs|
      FileUtils.mkdir_p(File.join(rootfs, 'etc'))
      FileUtils.mkdir_p(File.join(rootfs, 'etc/runit/core-services'))
      allow(OsCtld::ErbTemplate).to receive(:render_to_if_changed)

      config = OsCtld::DistConfig::Distributions::Void::Configurator.new('tank:ct1', rootfs, 'void', '1')

      config.set_hostname(hostname_class.new(local: 'ct1', fqdn: 'ct1.example'))

      expect(config.send(:network_class)).to be_nil
      expect(File.read(File.join(rootfs, 'etc/hostname'))).to eq("ct1\n")
      expect(OsCtld::ErbTemplate).to have_received(:render_to_if_changed).with(
        'dist_config/network/void/hostname',
        {},
        File.join(rootfs, 'etc/runit/core-services/10-vpsadminos-hostname.sh')
      )
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/VerifiedDoubles
