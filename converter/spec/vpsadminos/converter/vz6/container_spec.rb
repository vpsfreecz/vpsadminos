# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'vpsadminos-converter/user'
require 'vpsadminos-converter/group'
require 'vpsadminos-converter/vz6/container'

RSpec.describe VpsAdminOS::Converter::Vz6::Container do
  let(:vz_ct) { described_class.new('101') }
  let(:user) { VpsAdminOS::Converter::User.default }
  let(:group) { VpsAdminOS::Converter::Group.default }

  def config_from(text)
    VpsAdminOS::Converter::Vz6::Config.new('101', StringIO.new(text))
  end

  def netif_opts(type:, link: 'lxcbr0')
    {
      netif: {
        type:,
        name: 'eth0',
        hwaddr: '00:11:22:33:44:55',
        link:
      }
    }
  end

  it 'turns command success into a boolean for exist?' do
    allow(vz_ct).to receive(:syscmd).with('vzlist 101', valid_rcs: [1]).and_return(
      command_result('', exitstatus: 0)
    )

    expect(vz_ct.exist?).to be(true)

    allow(vz_ct).to receive(:syscmd).with('vzlist 101', valid_rcs: [1]).and_return(
      command_result('', exitstatus: 1)
    )

    expect(vz_ct.exist?).to be(false)
  end

  it 'parses container status output' do
    allow(vz_ct).to receive(:syscmd).with('vzctl status 101').and_return(
      command_result('CTID 101 exist mounted running')
    )

    expect(vz_ct.status).to eq(
      exist: true,
      mounted: true,
      running: true
    )
  end

  it 'delegates running? to the parsed status' do
    allow(vz_ct).to receive(:status).and_return(running: true)

    expect(vz_ct.running?).to be(true)
  end

  it 'loads config from the expected path' do
    config = instance_double(VpsAdminOS::Converter::Vz6::Config)

    allow(VpsAdminOS::Converter::Vz6::Config).to receive(:parse).and_return(config)

    vz_ct.load

    expect(VpsAdminOS::Converter::Vz6::Config).to have_received(:parse)
      .with('101', '/etc/vz/conf/101.conf')
    expect(vz_ct.config).to eq(config)
  end

  it 'raises when VE_LAYOUT is missing' do
    vz_ct.instance_variable_set(:@config, config_from("OSTEMPLATE=debian-12\n"))

    expect { vz_ct.layout }.to raise_error(RuntimeError, 'unable to determine VE_LAYOUT')
  end

  it 'detects ploop layout' do
    vz_ct.instance_variable_set(:@config, config_from("VE_LAYOUT=ploop\n"))

    expect(vz_ct.ploop?).to be(true)
  end

  it 'converts simfs containers using VE_PRIVATE and preserves unrelated items' do
    vz_ct.instance_variable_set(:@config, config_from(<<~CFG))
      VE_ROOT=/vz/root/$VEID
      VE_PRIVATE=/vz/private/$VEID
      VE_LAYOUT=simfs
      OSTEMPLATE=debian-12
      HOSTNAME=demo.example
      NAMESERVER="1.1.1.1 2001:db8::1"
      ONBOOT=yes
      PHYSPAGES=262144
      SWAPPAGES=131072
      IP_ADDRESS="192.0.2.10/24 2001:db8::10/64"
      DEVICES="b:8:0:rwq c:1:3:none"
      UNUSED=keep-me
    CFG

    ct = vz_ct.convert(user, group, netif_opts(type: :bridge))

    expect(ct.rootfs).to eq('/vz/private/101')
    expect(ct.distribution).to eq('debian')
    expect(ct.version).to eq('12')
    expect(ct.hostname).to eq('demo.example')
    expect(ct.dns_resolvers).to eq(%w[1.1.1.1 2001:db8::1])
    expect(ct.autostart.enabled).to be(true)
    expect(ct.cgparams['memory.limit_in_bytes']).to eq([262_144 * 4 * 1024])
    expect(ct.cgparams['memory.memsw.limit_in_bytes']).to eq(
      [(262_144 * 4 * 1024) + (131_072 * 4 * 1024)]
    )
    expect(ct.netifs.count).to eq(1)
    expect(ct.netifs.first.dump).to eq(
      'type' => 'bridge',
      'name' => 'eth0',
      'hwaddr' => '00:11:22:33:44:55',
      'ip_addresses' => {
        'v4' => ['192.0.2.10/24'],
        'v6' => ['2001:db8::10/64']
      },
      'link' => 'lxcbr0'
    )
    expect(ct.devices.dump).to eq(
      [
        {
          'type' => 'block',
          'major' => '8',
          'minor' => '0',
          'mode' => 'rw',
          'name' => nil,
          'inherit' => true
        },
        {
          'type' => 'char',
          'major' => '1',
          'minor' => '3',
          'mode' => '',
          'name' => nil,
          'inherit' => true
        }
      ]
    )
    expect(vz_ct.config['UNUSED'].consumed?).to be(false)
  end

  it 'converts routed interfaces and mirrors routes from addresses' do
    vz_ct.instance_variable_set(:@config, config_from(<<~CFG))
      VE_PRIVATE=/vz/private/$VEID
      VE_LAYOUT=simfs
      OSTEMPLATE=almalinux-9
      IP_ADDRESS="192.0.2.10/24 2001:db8::10/64"
    CFG

    ct = vz_ct.convert(user, group, netif_opts(type: :routed))

    expect(ct.netifs.first.dump).to eq(
      'type' => 'routed',
      'name' => 'eth0',
      'hwaddr' => '00:11:22:33:44:55',
      'ip_addresses' => {
        'v4' => ['192.0.2.10/24'],
        'v6' => ['2001:db8::10/64']
      },
      'routes' => {
        'v4' => ['192.0.2.10/24'],
        'v6' => ['2001:db8::10/64']
      }
    )
  end

  it 'uses VE_ROOT for ploop containers' do
    vz_ct.instance_variable_set(:@config, config_from(<<~CFG))
      VE_ROOT=/vz/root/$VEID
      VE_PRIVATE=/vz/private/$VEID
      VE_LAYOUT=ploop
      OSTEMPLATE=debian-12
    CFG

    ct = vz_ct.convert(user, group)

    expect(ct.rootfs).to eq('/vz/root/101')
  end

  it 'raises when OSTEMPLATE is missing' do
    vz_ct.instance_variable_set(:@config, config_from(<<~CFG))
      VE_PRIVATE=/vz/private/$VEID
      VE_LAYOUT=simfs
    CFG

    expect { vz_ct.convert(user, group) }.to raise_error(
      RuntimeError,
      'config missing OSTEMPLATE'
    )
  end

  it 'falls back to a default hostname when absent' do
    vz_ct.instance_variable_set(:@config, config_from(<<~CFG))
      VE_PRIVATE=/vz/private/$VEID
      VE_LAYOUT=simfs
      OSTEMPLATE=debian-12
    CFG

    ct = vz_ct.convert(user, group)

    expect(ct.hostname).to eq('vps')
  end
end
