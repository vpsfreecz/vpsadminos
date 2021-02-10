require 'osctld/dist_config/base'

module OsCtld
  class DistConfig::Debian < DistConfig::Base
    distribution :debian

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
          ct_syscmd(ct, 'hostname -F /etc/hostname')

        rescue SystemCommandFailed => e
          log(:warn, ct, "Unable to apply hostname: #{e.message}")
        end
      end
    end

    def network(_opts)
      base = File.join(ctrc.rootfs, 'etc', 'network')
      config = File.join(base, 'interfaces')
      return unless writable?(config)

      vars = {
        netifs: ct.netifs,
        head: nil,
        interfacesd: Dir.exist?(File.join(base, 'interfaces.d')),
        tail: nil,
      }

      %i(head tail).each do |v|
        f = File.join(base, "interfaces.#{v}")

        begin
          # Ignore large files
          if File.size(f) > 10*1024*1024
            log(:warn, ct, "/etc/network/interfaces.#{v} found, but is too large")
            next
          end

          vars[v] = File.read(f)
        rescue Errno::ENOENT
          next
        end
      end

      OsCtld::ErbTemplate.render_to(
        'dist_config/network/debian/interfaces',
        vars,
        config
      )
    end
  end
end
