{ config, lib, pkgs, utils, ... }:
#
# todo:
#   - crontab for scrubs, etc
#   - zfs tunables

with utils;
with lib;

let

  cfgSpl = config.boot.spl;
  cfgZfs = config.boot.zfs;
  cfgScrub = config.services.zfs.autoScrub;

  inInitrd = any (fs: fs == "zfs") config.boot.initrd.supportedFilesystems;
  inSystem = any (fs: fs == "zfs") config.boot.supportedFilesystems;

  enableZfs = inInitrd || inSystem;

  kernel = config.boot.kernelPackages;

  packages = {
    spl = kernel.spl;
    zfs = kernel.zfs;
    zfsUser = pkgs.zfs;
  };

  allPools = unique (cfgZfs.extraPools);

in

{

  ###### interface

  options = {
    boot.zfs = {
      poolName = mkOption {
        type = types.str;
        default = "tank";
        description = ''
          Name of the default pool.
        '';
      };

      poolLayout = mkOption {
        type = types.str;
        default = "# specify layout with boot.zfs.poolLayout";
        example = ''
          mirror sda sdb
        '';
        description = ''
          Pool layout to pass to zpool create. Pool is not created automatically
          and this is only used as a hint in stage-1 handler allowing to run
          creation manually.
        '';
      };

      extraPools = mkOption {
        type = types.listOf types.str;
        default = [ cfgZfs.poolName ];
        example = [ "tank" "data" ];
        description = ''
          Name or GUID of extra ZFS pools that you wish to import during boot.

          This imports boot.zfs.poolName (tank) by default, you can add extra pools if needed.
        '';
      };
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf enableZfs {
      boot = {
        kernelModules = [ "spl" "zfs" ] ;
        extraModulePackages = with packages; [ spl zfs ];
      };

      boot.initrd = mkIf inInitrd {
        kernelModules = [ "spl" "zfs" ];
        extraUtilsCommands =
          ''
            copy_bin_and_libs ${packages.zfsUser}/sbin/zfs
            copy_bin_and_libs ${packages.zfsUser}/sbin/zdb
            copy_bin_and_libs ${packages.zfsUser}/sbin/zpool
          '';
        extraUtilsCommandsTest = mkIf inInitrd
          ''
            $out/bin/zfs --help >/dev/null 2>&1
            $out/bin/zpool --help >/dev/null 2>&1
          '';
        postDeviceCommands = concatStringsSep "\n" ([''

            ''] ++ (map (pool: ''
            echo -n "importing ZFS pool \"${pool}\" "
            trial=0
            until msg="$(zpool import -N '${pool}' 2>&1)"; do
              sleep 0.25
              echo -n .
              trial=$(($trial + 1))
              if [[ $trial -eq 10 ]]; then
                echo
                fail "$msg"
                break
              fi
            done

            stat="$( zpool status ${pool} )"
            test $? && echo "$stat" | grep DEGRADED &> /dev/null && \
              echo -e "\n\n[1;31m>>> Pool is DEGRADED!! <<<[0m"
            echo
        '') allPools));
      };

      environment.etc."zfs/zed.d".source = "${packages.zfsUser}/etc/zfs/zed.d/";

      system.fsPackages = [ packages.zfsUser ]; # XXX: needed? zfs doesn't have (need) a fsck
      environment.systemPackages = [ packages.zfsUser ];

    })
  ];
}
