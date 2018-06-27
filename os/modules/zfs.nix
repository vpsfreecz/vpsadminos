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
      pool = {
        name = mkOption {
          type = types.str;
          default = "tank";
          description = ''
            Name of the default pool.
          '';
        };

        layout = mkOption {
          type = types.str;
          default = "# specify layout with boot.zfs.pool.layout";
          example = ''
            mirror sda sdb
          '';
          description = ''
            Pool layout to pass to zpool create. Pool is not created automatically
            and this is only used as a hint in stage-1 handler allowing to run
            creation manually. Pool can be created in either interactive shell
            or after the system boots.
          '';
        };

        logs = mkOption {
          type = types.str;
          default = "";
          example = ''
            mirror sde1 sdf1
          '';
          description = ''
            ZFS logs layout to pass to zpool add $pool.name log.
          '';
        };

        caches = mkOption {
          type = types.str;
          default = "";
          example = ''
            mirror sde2 sdf2
          '';
          description = ''
            ZFS caches layout to pass to zpool add $pool.name cache.
          '';
        };

        wipe = mkOption {
          type = types.listOf types.str;
          default = [];
          example = [ "sda" "sdb" ];
          description = ''
            Wipe disks prior to disk partitioning and pool creation (dangerous!).

            Uses dd to erase first and last 1024 sectors of the device.
          '';
          apply = map (d: ''
            dd if=/dev/zero of=/dev/${d} count=1024
            sectors="$( sfdisk -l /dev/${d} | egrep -o "([[:digit:]]+) sectors" | cut -d' ' -f1 )"
            dd if=/dev/zero of=/dev/${d} seek="$(( $sectors - 1024 ))" count=1024
          '');
        };

        partition = mkOption {
          type = types.attrsOf (types.attrsOf (types.submodule {
            options = {
              sizeGB = mkOption {
                type = types.nullOr types.ints.positive;
                default = null;
                description = "Partition size in gigabytes";
              };
              type = mkOption {
                type = types.enum [ "fd" ];
                default = "fd";
                description = "Partition type (list with `sfdisk -T`)";
              };
            };
          }));
          default = {};
          example = {
            sde = {
              p1 = { sizeGB=20; };
              p2 = { sizeGB=10; type="fd"; };
              p3 = {};
            };
          };
          description = ''
            Partition disks

            This creates a sfdisk input for simple partitioning, X in 'pX' means partition number.
            If sizeGB is not specified the rest of the dist will be used for this partition.
          '';
          apply = let
              toSectorSize = x: if x == null then "" else "size=${toString (x * 2048 * 1024)},";
                mkParts = x: concatStrings (intersperse "\n" (mapAttrsToList (n: v: "${replaceStrings ["p"] [""] n}:${toSectorSize v.sizeGB}type=${v.type}") x));
            in
              x: concatStrings (mapAttrsToList (k: v: "echo '${mkParts v};' | sfdisk /dev/${k}\n") x);
        };
      };

      extraPools = mkOption {
        type = types.listOf types.str;
        default = [ cfgZfs.pool.name ];
        example = [ "tank" "data" ];
        description = ''
          Name or GUID of extra ZFS pools that you wish to import during boot.

          This imports boot.zfs.pool.name (tank) by default, you can add extra pools if needed.
        '';
      };
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf enableZfs {
      boot = {
        kernelModules = [ "zfs" ] ;
        extraModulePackages = with packages; [ zfs ];
      };

      boot.initrd = mkIf inInitrd {
        kernelModules = [ "zfs" ];
        extraUtilsCommands =
          ''
            copy_bin_and_libs ${packages.zfsUser}/sbin/zfs
            copy_bin_and_libs ${packages.zfsUser}/sbin/zdb
            copy_bin_and_libs ${packages.zfsUser}/sbin/zpool
            ${optionalString (cfgZfs.pool.partition != []) ''
              copy_bin_and_libs ${pkgs.utillinux}/sbin/sfdisk
            ''}
          '';
        extraUtilsCommandsTest = mkIf inInitrd
          ''
            $out/bin/zfs --help >/dev/null 2>&1
            $out/bin/zpool --help >/dev/null 2>&1
            ${optionalString (cfgZfs.pool.partition != []) ''
              $out/bin/sfdisk --help >/dev/null 2>&1
            ''}
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
