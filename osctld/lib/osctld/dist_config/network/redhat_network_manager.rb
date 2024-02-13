require 'osctld/dist_config/network/base'
require 'osctld/dist_config/helpers/redhat'

module OsCtld
  # Configure network using RH style sysconfig with NetworkManager
  class DistConfig::Network::RedHatNetworkManager < DistConfig::Network::Base
    include DistConfig::Helpers::RedHat

    def usable?
      return false unless Dir.exist?(File.join(rootfs, 'etc/sysconfig/network-scripts'))
      return false unless Dir.exist?(File.join(rootfs, 'etc/NetworkManager/conf.d'))

      service = 'NetworkManager.service'

      # Check the service is not masked
      return false if systemd_service_masked?(service)

      # Check the service is enabled
      return false unless systemd_service_enabled?(service, 'multi-user.target')

      true
    end

    def configure(netifs)
      set_params(
        File.join(rootfs, 'etc/sysconfig/network'),
        { 'NETWORKING' => 'yes' }
      )

      netifs.each do |netif|
        do_create_netif(netif)
      end

      setup_for_nm(netifs)
    end

    # Cleanup old config files
    def remove_netif(netifs, netif)
      do_remove_netif(netif.name)
      setup_for_nm(netifs)
    end

    # Rename config files
    def rename_netif(netifs, netif, old_name)
      do_remove_netif(old_name)
      do_create_netif(netif)
      setup_for_nm(netifs)
    end

    protected

    def do_create_netif(netif)
      tpl_base = File.join('dist_config/network/redhat_network_manager')
      ct_base = File.join(rootfs, 'etc', 'sysconfig')
      ifcfg = File.join(ct_base, 'network-scripts', "ifcfg-#{netif.name}")

      return unless writable?(ifcfg)

      OsCtld::ErbTemplate.render_to_if_changed(
        File.join(tpl_base, netif.type.to_s, 'ifcfg'),
        { netif: },
        ifcfg
      )

      return unless netif.type == :routed

      netif.active_ip_versions.each do |ip_v|
        OsCtld::ErbTemplate.render_to_if_changed(
          File.join(tpl_base, netif.type.to_s, "route_v#{ip_v}"),
          { netif: },
          File.join(
            ct_base,
            'network-scripts',
            "route#{ip_v == 6 ? '6' : ''}-#{netif.name}"
          )
        )
      end
    end

    def do_remove_netif(name)
      base = File.join(rootfs, 'etc', 'sysconfig', 'network-scripts')
      files = [
        "ifcfg-#{name}",
        "route-#{name}",
        "route6-#{name}"
      ]

      files.each do |f|
        path = File.join(base, f)
        next if !File.exist?(path) || !writable?(path)

        File.unlink(path)
      end
    end

    def setup_for_nm(netifs)
      generate_nm_conf(netifs)
      generate_nm_udev_rules(netifs)
    end

    def generate_nm_conf(netifs)
      conf_d = File.join(rootfs, 'etc', 'NetworkManager', 'conf.d')
      return unless Dir.exist?(conf_d)

      file = File.join(conf_d, 'osctl.conf')
      return unless writable?(file)

      OsCtld::ErbTemplate.render_to_if_changed(
        File.join('dist_config/network/redhat_network_manager/nm_conf'),
        { netifs: },
        file
      )
    end

    def generate_nm_udev_rules(netifs)
      rules_d = File.join(rootfs, 'etc', 'udev', 'rules.d')
      return unless Dir.exist?(rules_d)

      file = File.join(rules_d, '86-osctl.rules')
      return unless writable?(file)

      OsCtld::ErbTemplate.render_to_if_changed(
        File.join('dist_config/network/redhat_network_manager/udev_rules'),
        { netifs: },
        file
      )
    end
  end
end
