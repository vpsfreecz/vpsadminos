{ config, lib, pkgs, utils, ... }@args:
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
  enableAutoScrub = cfgScrub.enable;

  kernel = config.boot.kernelPackages;

  packages = {
    spl = kernel.spl;
    zfs = kernel.zfs;
    zfsUser = pkgs.zfs;
  };

  partitioningSupport = elem true (mapAttrsToList (name: pool:
    pool.partition != []
  ) config.boot.zfs.pools);


  poolService = name: pool: (import ./pool-service.nix args) {
    inherit name pool zpoolCreateScript;
  };

  zpoolCreateScript = name: pool: (import ./pool-create.nix args) {
    inherit name pool;
  };

  zpoolCreateScripts = mapAttrsToList zpoolCreateScript;

  datasets = {
    options = {
      type = mkOption {
        type = types.enum [ "filesystem" "volume" ];
        default = "filesystem";
        description = "Dataset type";
      };

      properties = mkOption {
        type = types.attrs;
        default = {};
        description = "ZFS properties, see man zfs(8).";
      };
    };
  };

  pools = {
    options = {
      layout = mkOption {
        type = types.str;
        default = "# specify layout with boot.zfs.pools.<pool>.layout";
        example = ''
          mirror sda sdb
        '';
        description = ''
          Pool layout to pass to zpool create. The pool can be created either
          manually using script <literal>do-create-pool-&lt;pool&gt;</literal>
          or automatically when <option>boot.zfs.pools.&lt;pool&gt;.doCreate</option>
          is set and the pool cannot be imported.
        '';
      };

      logs = mkOption {
        type = types.str;
        default = "";
        example = ''
          mirror sde1 sdf1
        '';
        description = ''
          ZFS logs layout to pass to zpool add $pool log.
        '';
      };

      caches = mkOption {
        type = types.str;
        default = "";
        example = ''
          mirror sde2 sdf2
        '';
        description = ''
          ZFS caches layout to pass to zpool add $pool cache.
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
      };

      doCreate = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Determines whether disks are partitioned and zpool is created when
          the pool cannot be imported, suggesting it does not exist.

          Do not enable this in production, existing pools might fail to import
          for unforeseen reasons and recreating them will result in data loss.
        '';
      };

      install = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Import the pool into osctld to be used for containers.
        '';
      };

      properties = mkOption {
        type = types.attrs;
        default = {};
        example = {
          readonly = on;
        };
        description = ''
          zpool properties, see man zpool(8) for more information.
        '';
      };

      datasets = mkOption {
        type = types.attrsOf (types.submodule datasets);
        default = {};
        example = {
          "/".properties.sharenfs = "on";
          "data".properties.quota = "100G";
          "volume" = {
            type = "volume";
            properties.volsize = "50G";
          };
        };
        description = ''
          Declaratively create ZFS file systems or volumes and configure
          properties.

          Dataset names are relative to the pool and optionally may start with
          a slash. Configured properties are passed directly to ZFS, see
          man zfs(8) for more information.

          No dataset is ever destroyed and properties removed from
          the configuration are not unset once deployed. To reset a property,
          set its value to `inherit`.
        '';
      };
    };
  };

in

{

  ###### interface

  options = {
    boot.zfs = {
      pools = mkOption {
        type = types.attrsOf (types.submodule pools);
      };
    };

    services.zfs.autoScrub = {
      enable = mkOption {
        default = false;
        type = types.bool;
        description = ''
          Enables periodic scrubbing of ZFS pools.
        '';
      };

      interval = mkOption {
        default = "0 4 */14 * *";
        type = types.str;
        description = ''
          Date and time expression for when to scrub ZFS pools in a crontab
          format, i.e. minute, hour, day of month, month and day of month
          separated by spaces.
        '';
      };

      pools = mkOption {
        default = [];
        type = types.listOf types.str;
        example = [ "tank" ];
        description = ''
          List of ZFS pools to periodically scrub. If empty, all pools
          will be scrubbed.
        '';
      };
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf enableZfs {
      assertions = [
        (
          let
            filterDatasets = pool: foldr ({k,v}: acc:
              if v.type == "volume" && !(hasAttr "volsize" v.properties) then
                acc ++ [(concatStringsSep "/" [pool k])]
              else
                acc
            ) [];

            filterPools = foldr ({k,v}: acc:
              acc ++ (filterDatasets k (mapAttrsToList (k: v: {inherit k v;}) v))
            ) [];

            pools = filterPools (mapAttrsToList (k: v: {k = k; v = v.datasets;}) cfgZfs.pools);

            msg = concatMapStringsSep ", " (v: v) pools;
          in {
            assertion = length pools == 0;
            message = "These volumes are missing the volsize property: " + msg;
          }
        )
      ];

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
            ${optionalString partitioningSupport ''
              copy_bin_and_libs ${pkgs.utillinux}/sbin/sfdisk
            ''}
          '';
        extraUtilsCommandsTest = mkIf inInitrd
          ''
            $out/bin/zfs --help >/dev/null 2>&1
            $out/bin/zpool --help >/dev/null 2>&1
            ${optionalString partitioningSupport ''
              $out/bin/sfdisk --help >/dev/null 2>&1
            ''}
          '';
      };

      runit.services = mapAttrs' (name: pool:
        nameValuePair "pool-${name}" (poolService name pool)
      ) cfgZfs.pools;

      environment.etc."zfs/zed.d".source = "${packages.zfsUser}/etc/zfs/zed.d/";

      system.fsPackages = [ packages.zfsUser ]; # XXX: needed? zfs doesn't have (need) a fsck
      environment.systemPackages = [ packages.zfsUser ] ++ (zpoolCreateScripts cfgZfs.pools);
    })

    (mkIf enableAutoScrub {
      services.cron.systemCronJobs =
        let
          zpools = if cfgScrub.pools == [] then
              "$(${packages.zfsUser}/bin/zpool list -H -o name)"
            else
              concatStringsSep " " cfgScrub.pools;
        in ["${cfgScrub.interval} root ${packages.zfsUser}/bin/zpool scrub ${zpools}"];
    })
  ];
}
