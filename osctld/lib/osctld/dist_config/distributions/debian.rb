require 'osctld/dist_config/distributions/base'

module OsCtld
  class DistConfig::Distributions::Debian < DistConfig::Distributions::Base
    distribution :debian

    class Configurator < DistConfig::Configurator
      def set_hostname(new_hostname, old_hostname: nil)
        # /etc/hostname
        writable?(File.join(rootfs, 'etc', 'hostname')) do |path|
          regenerate_file(path, 0o644) do |f|
            f.puts(new_hostname.local)
          end
        end
      end

      def network_class
        DistConfig::Network::Ifupdown
      end
    end

    def apply_hostname
      ct_syscmd(ct, %w[hostname -F /etc/hostname])
    rescue SystemCommandFailed => e
      log(:warn, ct, "Unable to apply hostname: #{e.message}")
    end
  end
end
