require 'osctld/dist_config/base'

module OsCtld
  class DistConfig::OpenSuse < DistConfig::Base
    distribution :opensuse

    class Configurator < DistConfig::Configurator
      def set_hostname(new_hostname, old_hostname: nil)
        # /etc/hostname
        writable?(File.join(rootfs, 'etc', 'hostname')) do |path|
          regenerate_file(path, 0644) do |f|
            f.puts(new_hostname.local)
          end
        end
      end

      def network(netifs)
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
        tpl_base = File.join('dist_config/network', 'opensuse')
        ct_base = File.join(rootfs, 'etc', 'sysconfig')
        ifcfg = File.join(ct_base, 'network', "ifcfg-#{netif.name}")

        return unless writable?(ifcfg)

        OsCtld::ErbTemplate.render_to(
          File.join(tpl_base, netif.type.to_s, 'ifcfg'),
          {
            netif: netif,
            all_ips: netif.active_ip_versions.inject([]) do |acc, ip_v|
              acc.concat(netif.ips(ip_v))
            end,
          },
          ifcfg
        )

        OsCtld::ErbTemplate.render_to(
          File.join(tpl_base, netif.type.to_s, 'ifroute'),
          {netif: netif},
          File.join(
            ct_base,
            'network',
            "ifroute-#{netif.name}"
          )
        )
      end

      def do_remove_netif(name)
        base = File.join(rootfs, 'etc', 'sysconfig', 'network')
        files = [
          "ifcfg-#{name}",
        ]

        files.each do |f|
          path = File.join(base, f)
          next if !File.exist?(path) || !writable?(path)

          File.unlink(path)
        end
      end
    end

    def apply_hostname
      begin
        ct_syscmd(ct, ['hostname', ct.hostname.fqdn])

      rescue SystemCommandFailed => e
        log(:warn, ct, "Unable to apply hostname: #{e.message}")
      end
    end
  end
end
