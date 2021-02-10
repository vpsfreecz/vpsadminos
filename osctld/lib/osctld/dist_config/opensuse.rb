require 'osctld/dist_config/base'

module OsCtld
  class DistConfig::OpenSuse < DistConfig::Base
    distribution :opensuse

    def set_hostname(opts)
      # /etc/hostname
      writable?(File.join(ctrc.rootfs, 'etc', 'hostname')) do |path|
        regenerate_file(path, 0644) do |f|
          f.puts(ct.hostname.local)
        end
      end

      # Entry in /etc/hosts
      update_etc_hosts(opts[:original])

      # Apply hostname if the container is running
      if ct.running?
        begin
          ct_syscmd(ct, "hostname #{ct.hostname}")

        rescue SystemCommandFailed => e
          log(:warn, ct, "Unable to apply hostname: #{e.message}")
        end
      end
    end

    def network(_opts)
      ct.netifs.each do |netif|
        do_create_netif(netif)
      end
    end

    # Cleanup old config files
    def remove_netif(opts)
      do_remove_netif(opts[:netif].name)
    end

    # Rename config files
    def rename_netif(opts)
      do_remove_netif(opts[:original_name])
      do_create_netif(opts[:netif])
    end

    protected
    def do_create_netif(netif)
      tpl_base = File.join('dist_config/network', 'opensuse')
      ct_base = File.join(ctrc.rootfs, 'etc', 'sysconfig')
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
      base = File.join(ctrc.rootfs, 'etc', 'sysconfig', 'network')
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
end
