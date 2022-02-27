require 'osctld/dist_config/distributions/base'

module OsCtld
  class DistConfig::Distributions::Gentoo < DistConfig::Distributions::Base
    distribution :gentoo

    class Configurator < DistConfig::Configurator
      def set_hostname(new_hostname, old_hostname: nil)
        # /etc/hostname
        writable?(File.join(rootfs, 'etc', 'conf.d', 'hostname')) do |path|
          regenerate_file(path, 0644) do |f|
            f.puts('# Set to the hostname of this machine')
            f.puts("hostname=\"#{new_hostname}\"")
          end
        end
      end

      protected
      def network_class
        DistConfig::Network::Netifrc
      end
    end

    def apply_hostname
      begin
        ct_syscmd(ct, ['hostname', ct.hostname.local])

      rescue SystemCommandFailed => e
        log(:warn, ct, "Unable to apply hostname: #{e.message}")
      end
    end
  end
end
