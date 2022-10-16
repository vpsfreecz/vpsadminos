require 'osctld/dist_config/distributions/base'
require 'osctld/dist_config/helpers/redhat'

module OsCtld
  class DistConfig::Distributions::RedHat < DistConfig::Distributions::Base

    class Configurator < DistConfig::Configurator
      include DistConfig::Helpers::RedHat

      def set_hostname(new_hostname, old_hostname: nil)
        # /etc/hostname
        writable?(File.join(rootfs, 'etc', 'hostname')) do |path|
          regenerate_file(path, 0644) do |f|
            f.puts(new_hostname.local)
          end
        end

        # /etc/sysconfig/network for older systems
        set_params(
          File.join(rootfs, 'etc', 'sysconfig', 'network'),
          {'HOSTNAME' => new_hostname.local}
        )
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
