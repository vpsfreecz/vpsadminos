require 'osctld/dist_config/base'

module OsCtld
  class DistConfig::NixOS < DistConfig::Base
    distribution :nixos

    def set_hostname(opts)
      log(:warn, ct, "Unable to apply hostname to NixOS container")
    end

    def network(_opts)
      tpl_base = 'dist_config/network/nixos'

      ["add", "del"].each do |operation|

        cmds = ct.netifs.map do |netif|
          OsCtld::Template.render(
            File.join(tpl_base, netif.type.to_s),
            {netif: netif, op: operation}
          )
        end

        File.write(
          File.join(ct.rootfs, "ifcfg.#{operation}"),
          cmds.join("\n")
        )

      end
    end

    def bin_path(_opts)
      system = File.readlink(File.join(ct.rootfs, '/run/current-system'))
      sw = File.readlink(File.join(ct.rootfs, system, 'sw'))
      File.join(sw, 'bin')
    end
  end
end
