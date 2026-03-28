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
