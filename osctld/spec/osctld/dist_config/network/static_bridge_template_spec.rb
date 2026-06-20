# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass

require 'ipaddress'
require 'osctld/erb_template'
require 'osctld/erb_template_cache'

RSpec.describe 'static bridge network templates' do
  def render_bridge_template(template, gateway)
    gateway_waits = []
    netif = Struct.new(:name, :dhcp, :gateway, :gateway_waits, keyword_init: true) do
      def active_ip_versions
        [4]
      end

      def ips(version)
        return [] unless version == 4

        [IPAddress.parse('192.168.1.36/24')]
      end

      def gateway_or_nil(version, wait: false)
        gateway_waits << [version, wait]
        gateway
      end
    end.new(name: 'eth0', dhcp: false, gateway:, gateway_waits:)

    [
      OsCtld::ErbTemplate.render(template, netif:),
      gateway_waits
    ]
  end

  before do
    unless OsCtld.respond_to?(:template_dir)
      OsCtld.define_singleton_method(:template_dir) { nil }
    end

    allow(OsCtld).to receive(:template_dir).and_return(
      File.expand_path('../../../../templates', __dir__)
    )

    OsCtld::ErbTemplateCache.instance.load
  end

  it 'renders waited static bridge gateways into netctl profiles' do
    rendered, gateway_waits = render_bridge_template(
      'dist_config/network/netctl/bridge',
      '192.168.1.1'
    )

    expect(rendered).to include('Address=( "192.168.1.36/24" )')
    expect(rendered).to include("Gateway=192.168.1.1\n")
    expect(gateway_waits).to eq([[4, true]])
  end

  it 'renders waited static bridge gateways into systemd-networkd profiles' do
    rendered, gateway_waits = render_bridge_template(
      'dist_config/network/systemd_networkd/bridge',
      '192.168.1.1'
    )

    expect(rendered).to include("Address=192.168.1.36/24\n")
    expect(rendered).to include("Gateway=192.168.1.1\n")
    expect(gateway_waits).to eq([[4, true]])
  end

  it 'omits gateway fields when no bridge gateway is available' do
    netctl_rendered, netctl_gateway_waits = render_bridge_template(
      'dist_config/network/netctl/bridge',
      nil
    )
    networkd_rendered, networkd_gateway_waits = render_bridge_template(
      'dist_config/network/systemd_networkd/bridge',
      nil
    )

    expect(netctl_rendered).not_to include('Gateway=')
    expect(networkd_rendered).not_to include('Gateway=')
    expect(netctl_gateway_waits).to eq([[4, true]])
    expect(networkd_gateway_waits).to eq([[4, true]])
  end
end

# rubocop:enable RSpec/DescribeClass
