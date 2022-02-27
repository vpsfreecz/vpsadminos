require 'osctld/dist_config/distributions/base'
require 'fileutils'

module OsCtld
  class DistConfig::Distributions::Arch < DistConfig::Distributions::Base
    distribution :arch

    class Configurator < DistConfig::Configurator
      def set_hostname(new_hostname, old_hostname: nil)
        # /etc/hostname
        writable?(File.join(rootfs, 'etc', 'hostname')) do |path|
          regenerate_file(path, 0644) do |f|
            f.puts(new_hostname.local)
          end
        end
      end

      protected
      def network_class
        [
          DistConfig::Network::SystemdNetworkd,
          DistConfig::Network::Netctl,
        ]
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
