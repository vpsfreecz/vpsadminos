require 'osctld/dist_config/base'

module OsCtld
  class DistConfig::Debian < DistConfig::Base
    distribution :debian

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
        base = File.join(rootfs, 'etc', 'network')
        config = File.join(base, 'interfaces')
        return unless writable?(config)

        vars = {
          netifs: netifs,
          head: nil,
          interfacesd: Dir.exist?(File.join(base, 'interfaces.d')),
          tail: nil,
        }

        %i(head tail).each do |v|
          f = File.join(base, "interfaces.#{v}")

          begin
            # Ignore large files
            if File.size(f) > 10*1024*1024
              log(:warn, "/etc/network/interfaces.#{v} found, but is too large")
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

    def apply_hostname
      begin
        ct_syscmd(ct, %w(hostname -F /etc/hostname))

      rescue SystemCommandFailed => e
        log(:warn, ct, "Unable to apply hostname: #{e.message}")
      end
    end
  end
end
