# frozen_string_literal: true

require 'spec_helper'
require 'ipaddress'
require 'vpsadminos-converter/net_interface/bridge'
require 'vpsadminos-converter/net_interface/routed'

RSpec.describe VpsAdminOS::Converter::NetInterface do
  let(:base_class) { VpsAdminOS::Converter::NetInterface::Base }
  let(:bridge_class) { VpsAdminOS::Converter::NetInterface::Bridge }
  let(:routed_class) { VpsAdminOS::Converter::NetInterface::Routed }

  it 'registers and resolves interface types' do
    custom_class = Class.new(base_class)
    custom_class.type(:custom)

    expect(described_class.for(:custom)).to eq(custom_class)
  end

  it 'returns the configured class type' do
    expect(bridge_class.type).to eq(:bridge)
    expect(routed_class.type).to eq(:routed)
  end

  it 'dumps base interfaces with ip addresses by family' do
    netif = base_class.new('eth0', '00:11:22:33:44:55')
    netif.ip_addresses[4] << IPAddress.parse('192.0.2.10/24')
    netif.ip_addresses[6] << IPAddress.parse('2001:db8::10/64')

    expect(netif.dump).to eq(
      'type' => '',
      'name' => 'eth0',
      'hwaddr' => '00:11:22:33:44:55',
      'ip_addresses' => {
        'v4' => ['192.0.2.10/24'],
        'v6' => ['2001:db8::10/64']
      }
    )
  end

  it 'dumps bridged interfaces with the bridge link' do
    netif = bridge_class.new('eth0')
    netif.link = 'lxcbr0'

    expect(netif.dump).to eq(
      'type' => 'bridge',
      'name' => 'eth0',
      'hwaddr' => nil,
      'ip_addresses' => {
        'v4' => [],
        'v6' => []
      },
      'link' => 'lxcbr0'
    )
  end

  it 'dumps routed interfaces with routes by family' do
    netif = routed_class.new('eth0')
    netif.ip_addresses[4] << IPAddress.parse('192.0.2.10/24')
    netif.ip_addresses[6] << IPAddress.parse('2001:db8::10/64')
    netif.routes = {
      4 => [IPAddress.parse('192.0.2.1/32')],
      6 => [IPAddress.parse('2001:db8::1/128')]
    }

    expect(netif.dump).to eq(
      'type' => 'routed',
      'name' => 'eth0',
      'hwaddr' => nil,
      'ip_addresses' => {
        'v4' => ['192.0.2.10/24'],
        'v6' => ['2001:db8::10/64']
      },
      'routes' => {
        'v4' => ['192.0.2.1/32'],
        'v6' => ['2001:db8::1/128']
      }
    )
  end
end
