require 'osctld/dist_config/distributions/base'

module OsCtld
  class DistConfig::Distributions::NixOS < DistConfig::Distributions::Base
    distribution :nixos

    class Configurator < DistConfig::Configurator
      def set_hostname(new_hostname, old_hostname: nil)
        log(:warn, "Unable to apply hostname to NixOS container")
      end

      def network(netifs)
        tpl_base = 'dist_config/network/nixos'

        %w(add del).each do |operation|

          cmds = netifs.map do |netif|
            OsCtld::ErbTemplate.render(
              File.join(tpl_base, netif.type.to_s),
              {netif: netif, op: operation}
            )
          end

          writable?(File.join(rootfs, "ifcfg.#{operation}")) do |path|
            File.write(path, cmds.join("\n"))
          end

        end
      end

      protected
      def network_class
        nil
      end
    end

    def bin_path(_opts)
      with_rootfs do
        begin
          File.realpath('/nix/var/nix/profiles/system/sw/bin')
        rescue Errno::ENOENT
          '/bin'
        end
      end
    end
  end
end
