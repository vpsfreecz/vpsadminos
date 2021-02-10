require 'osctld/dist_config/base'

module OsCtld
  class DistConfig::NixOS < DistConfig::Base
    distribution :nixos

    def set_hostname(opts)
      log(:warn, ct, "Unable to apply hostname to NixOS container")
    end

    def network(_opts)
      tpl_base = 'dist_config/network/nixos'

      %w(add del).each do |operation|

        cmds = ct.netifs.map do |netif|
          OsCtld::ErbTemplate.render(
            File.join(tpl_base, netif.type.to_s),
            {netif: netif, op: operation}
          )
        end

        writable?(File.join(ctrc.rootfs, "ifcfg.#{operation}")) do |path|
          File.write(path, cmds.join("\n"))
        end

      end
    end

    def bin_path(_opts)
      begin
        system = File.readlink(File.join(ct.runtime_rootfs, '/run/current-system'))

      rescue RuntimeError
        system = File.readlink(File.join(ctrc.rootfs, '/run/current-system'))
      end

      sw = File.readlink(File.join(ctrc.rootfs, system, 'sw'))
      File.join(sw, 'bin')
    end
  end
end
