require 'osctld/dist_config/network/base'
require 'osctld/dist_config/helpers/redhat'

module OsCtld
  # Configure network using RH style sysconfig with initscripts
  class DistConfig::Network::RedHatInitScripts < DistConfig::Network::Base
    include DistConfig::Helpers::RedHat

    def configure(netifs)
      set_params(
        File.join(rootfs, 'etc/sysconfig/network'),
        {'NETWORKING' => 'yes'}
      )

      netifs.each do |netif|
        do_create_netif(netif)
      end
    end

    # Cleanup old config files
    def remove_netif(netifs, netif)
      do_remove_netif(netif.name)
    end

    # Rename config files
    def rename_netif(netifs, netif, old_name)
      do_remove_netif(old_name)
      do_create_netif(netif)
    end

    protected
    def do_create_netif(netif)
      tpl_base = File.join('dist_config/network/redhat_initscripts')
      ct_base = File.join(rootfs, 'etc', 'sysconfig')
      ifcfg = File.join(ct_base, 'network-scripts', "ifcfg-#{netif.name}")

      return unless writable?(ifcfg)

      OsCtld::ErbTemplate.render_to(
        File.join(tpl_base, netif.type.to_s, 'ifcfg'),
        {netif: netif},
        ifcfg
      )

      if netif.type == :routed
        netif.active_ip_versions.each do |ip_v|
          OsCtld::ErbTemplate.render_to(
            File.join(tpl_base, netif.type.to_s, "route_v#{ip_v}"),
            {netif: netif},
            File.join(
              ct_base,
              'network-scripts',
              "route#{ip_v == 6 ? '6' : ''}-#{netif.name}"
            )
          )
        end
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
  end
end
