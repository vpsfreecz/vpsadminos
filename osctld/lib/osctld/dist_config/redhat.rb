module OsCtld
  class DistConfig::RedHat < DistConfig::Base
    def set_hostname(opts)
      # /etc/sysconfig/network
      set_params(
        File.join(ct.rootfs, 'etc', 'sysconfig', 'network'),
        {'HOSTNAME' => ct.hostname}
      )

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
      tpl_base = 'dist_config/network/redhat'
      ct_base = File.join(ct.rootfs, 'etc', 'sysconfig')

      set_params(File.join(ct_base, 'network'), {'NETWORKING' => 'yes'})

      ct.netifs.each do |netif|
        OsCtld::Template.render_to(
          File.join(tpl_base, netif.type.to_s, 'ifcfg'),
          {netif: netif},
          File.join(ct_base, 'network-scripts', "ifcfg-#{netif.name}")
        )

        if netif.type == :routed
          netif.active_ip_versions.each do |ip_v|
            OsCtld::Template.render_to(
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
    end

    # Cleanup old config files
    def remove_netif(opts)
      base = File.join(ct.rootfs, 'etc', 'sysconfig', 'network-scripts')
      files = [
        "ifcfg-#{opts[:netif].name}",
        "route-#{opts[:netif].name}",
        "route6-#{opts[:netif].name}"
      ]

      files.each do |f|
        path = File.join(base, f)
        next unless File.exist?(path)

        File.unlink(path)
      end
    end

    # Rename config files
    def rename_netif(opts)
      base = File.join(ct.rootfs, 'etc', 'sysconfig', 'network-scripts')
      files = [
        "ifcfg-%{name}",
        "route-%{name}",
        "route6-%{name}",
      ]

      files.each do |f|
        orig = File.join(base, f % {name: opts[:original_name]})
        new = File.join(base, f % {name: opts[:netif].name})

        next unless File.exist?(orig)

        File.rename(orig, new)
      end
    end

    protected
    # @param file [String]
    # @param params [Hash]
    def set_params(file, params)
      regenerate_file(file, 0644) do |new, old|
        if old
          # Overwrite existing params and keep unchanged ones
          old.each_line do |line|
            param, value = params.detect { |k, v| /^#{k}=/ =~ line }

            if param
              new.puts("#{param}=\"#{value}\"")
              params.delete(param)

            else
              new.write(line)
            end
          end

          # Write new params
          params.each do |k, v|
            new.puts("#{k}=\"#{v}\"")
          end

        else
          # File did not exist, write all params
          params.each do |k, v|
            new.puts("#{k}=\"#{v}\"")
          end
        end
      end
    end
  end
end
