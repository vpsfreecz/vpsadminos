# frozen_string_literal: true

require 'spec_helper'
require 'ipaddress'
require 'vpsadminos-converter/container'
require 'vpsadminos-converter/user'
require 'vpsadminos-converter/group'
require 'vpsadminos-converter/net_interface/bridge'

RSpec.describe VpsAdminOS::Converter::Container do
  subject(:container) { described_class.new('101', user, group) }

  let(:user) { VpsAdminOS::Converter::User.default }
  let(:group) { VpsAdminOS::Converter::Group.default }

  it 'uses the expected defaults' do
    expect(container.distribution).to eq('unknown')
    expect(container.arch).to eq(`uname -m`.strip)
    expect(container.hostname).to eq('ct')
    expect(container.nesting).to be(false)
    expect(container.dns_resolvers).to eq([])
    expect(container.netifs).to eq([])
    expect(container.cgparams.dump).to eq([])
    expect(container.devices.dump).to eq([])
    expect(container.autostart.enabled).to be(false)
  end

  it 'returns the root dataset and descendants' do
    child = fake_dataset(name: 'tank/ct/101/data', relative_name: 'data')
    container.dataset = fake_dataset(
      name: 'tank/ct/101',
      descendants: [child]
    )

    expect(container.datasets).to eq([container.dataset, child])
  end

  it 'memoizes datasets once computed' do
    child = fake_dataset(name: 'tank/ct/101/data', relative_name: 'data')
    container.dataset = fake_dataset(
      name: 'tank/ct/101',
      descendants: [child]
    )

    first = container.datasets
    container.dataset.descendants << fake_dataset(name: 'tank/ct/101/log', relative_name: 'log')

    expect(container.datasets).to equal(first)
    expect(container.datasets).to eq([container.dataset, child])
  end

  it 'serializes the full container config' do
    container.distribution = 'debian'
    container.version = '12'
    container.hostname = 'demo'
    container.nesting = true
    container.dns_resolvers.push('1.1.1.1', '8.8.8.8')
    container.cgparams.set('memory.limit_in_bytes', 1024)
    container.devices << VpsAdminOS::Converter::Devices::Device.new(
      'char', '1', '3', 'rwm', name: 'null'
    )
    container.autostart.enabled = true
    container.autostart.priority = 30
    container.autostart.delay = 15

    netif = VpsAdminOS::Converter::NetInterface::Bridge.new('eth0', '00:11:22:33:44:55')
    netif.link = 'lxcbr0'
    netif.ip_addresses[4] << IPAddress.parse('192.0.2.10/24')
    container.netifs << netif

    expect(container.dump_config).to eq(
      'user' => 'default',
      'group' => 'default',
      'distribution' => 'debian',
      'version' => '12',
      'arch' => `uname -m`.strip,
      'net_interfaces' => [netif.dump],
      'cgparams' => [
        {
          'subsystem' => 'memory',
          'name' => 'memory.limit_in_bytes',
          'value' => [1024]
        }
      ],
      'devices' => [
        {
          'type' => 'char',
          'major' => '1',
          'minor' => '3',
          'mode' => 'rwm',
          'name' => 'null',
          'inherit' => true
        }
      ],
      'prlimits' => [],
      'mounts' => [],
      'autostart' => {
        'priority' => 30,
        'delay' => 15
      },
      'hostname' => 'demo',
      'dns_resolvers' => %w[1.1.1.1 8.8.8.8],
      'nesting' => true
    )
  end

  it 'serializes empty dns resolvers as nil' do
    expect(container.dump_config['dns_resolvers']).to be_nil
  end
end
