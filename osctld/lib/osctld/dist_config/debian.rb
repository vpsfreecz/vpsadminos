module OsCtld
  class DistConfig::Debian < DistConfig::Base
    distribution :debian

    def set_hostname(opts)
      # /etc/hostname
      regenerate_file(File.join(ct.rootfs, 'etc', 'hostname'), 0644) do |f|
        f.puts(ct.hostname)
      end

      # Entry in /etc/hosts
      update_etc_hosts(opts[:original])

      # Apply hostname if the container is running
      if ct.running?
        begin
          ct_syscmd(ct, 'hostname -F /etc/hostname')

        rescue SystemCommandFailed => e
          log(:warn, ct, "Unable to apply hostname: #{e.message}")
        end
      end
    end

    def network(_opts)
      base = File.join(ct.rootfs, 'etc', 'network')
      vars = {
        netifs: ct.netifs,
        interfacesd: Dir.exist?(File.join(base, 'interfaces.d')),
      }

      %i(head tail).each do |v|
        vars[v] = File.exist?(File.join(base, "interfaces.#{v}"))
      end

      OsCtld::Template.render_to(
        'dist_config/network/debian/interfaces',
        vars,
        File.join(ct.rootfs, 'etc', 'network', 'interfaces')
      )
    end
  end
end
