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

  zfsFilesystems = filter (x: x.fsType == "zfs") config.system.build.fileSystems;

  datasetToPool = x: elemAt (splitString "/" x) 0;

  fsToPool = fs: datasetToPool fs.device;

  rootPools = unique (map fsToPool (filter fsNeededForBoot zfsFilesystems));

  # safe import of ZFS pool
  # according to https://github.com/NixOS/nixpkgs/commit/cfd8c4ee88fec3a7f989663e09d8e39513b8488e
  importLib = {zpoolCmd, awkCmd, cfgZfs}:
    let
      devOptions = concatMapStringsSep " " (v: "-d \"${v}\"") cfgZfs.devNodes;

    in ''
      poolReady() {
        pool="$1"
        guid="$2"

        if [[ "$guid" = "" ]] ; then
          state="$(${zpoolCheckScript} ${devOptions} "$pool")"
        else
          state="$(${zpoolCheckScript} ${devOptions} "$pool" "$guid")"
        fi
        if [[ "$state" = "ONLINE" ]]; then
          return 0
        else
          echo "Pool $pool in state $state, waiting"
          return 1
        fi
      }
      poolImported() {
        pool="$1"
        "${zpoolCmd}" list "$pool" >/dev/null 2>/dev/null
      }
      poolImport() {
        pool="$1"
        "${zpoolCmd}" import ${devOptions} -N $ZFS_FORCE "$pool"
      }
    '';

  importLibInstance = importLib {
    zpoolCmd = "${packages.zfsUser}/bin/zpool";
    awkCmd = "awk";
    inherit cfgZfs;
  };

  poolService = name: pool: (import ./pool-service.nix args) {
    inherit name pool zpoolCreateScript packages;
    importLib = importLibInstance;
  };

  poolConfig = name: pool: pkgs.writeText "pool-${name}-config.json" (builtins.toJSON {
    inherit (pool) layout spare log cache partition wipe properties install;
  });

  zpoolCreateScript = name: pool: pkgs.runCommand "do-create-pool-${name}" {
    ruby = pkgs.ruby;
    poolName = name;
    poolConfig = poolConfig name pool;
  } ''
    mkdir -p $out/bin
    substituteAll ${./create.rb} $out/bin/do-create-pool-${name}
    chmod +x $out/bin/do-create-pool-${name}
  '';

  zpoolCheckScript = pkgs.substituteAll {
    name = "check-zpool.rb";
    src = ./check.rb;
    isExecutable = true;
    ruby = pkgs.ruby;
    zfsUser = packages.zfsUser;
  };

  zpoolCreateScripts = mapAttrsToList zpoolCreateScript;

  layoutVdev = {
    options = {
      type = mkOption {
        type = types.enum [
          "stripe"
          "mirror"
          "raidz"
          "raidz1"
          "raidz2"
          "raidz3"
        ];
        default = "stripe";
        example = "mirror";
        description = ''
          Virtual device type, see man zpool(8) for more information.
        '';
      };

      devices = mkOption {
        type = types.listOf types.str;
        description = ''
          List of device names.
        '';
      };
    };
  };

  logVdev = {
    options = {
      mirror = mkOption {
        type = types.bool;
        description = ''
          Determines whether the log devices will be mirrored or not.
        '';
      };

      devices = mkOption {
        type = types.listOf types.str;
        description = ''
          List of device names.
        '';
      };
    };
  };

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
      guid = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Pool ID used for importing.
        '';
      };

      layout = mkOption {
        type = types.listOf (types.submodule layoutVdev);
        default = [];
        description = ''
          Pool layout to pass to zpool create. The pool can be created either
          manually using script <literal>do-create-pool-&lt;pool&gt;</literal>
          or automatically when <option>boot.zfs.pools.&lt;pool&gt;.doCreate</option>
          is set and the pool cannot be imported.
        '';
      };

      log = mkOption {
        type = types.listOf (types.submodule logVdev);
        default = [];
        example = {
          mirror = true;
          devices = [ "sde1" "sdf1" ];
        };
        description = ''
          Devices used for ZFS Intent Log (ZIL).
        '';
      };

      cache = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "sde2" "sdf2" ];
        description = ''
          Devices used for secondary read cache (L2ARC).
        '';
      };

      spare = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          List of devices to be used as hot spares.
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
          readonly = "on";
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

      share = mkOption {
        type = types.enum [ "always" "once" "off" ];
        default = "always";
        description = ''
          Determines whether ZFS filesystems with sharenfs set should be
          exported.

          When set to <literal>always</literal>, <literal>zfs share</literal>
          is run every time the service is started. When set to
          <literal>once</literal>, filesystems are exported only once for this
          pool, e.g. when the service is restarted on upgrade, filesystems are
          not reexported. <literal>off</literal> disables automated exporting
          completely.
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
      forceImportRoot = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Forcibly import the ZFS root pool(s) during early boot.
        '';
      };
      devNodes = mkOption {
        type = types.listOf types.str;
        default = [ "/dev/disk/by-id" ];
        description = ''
          Directories used to search disk devices.

          This should be a path under /dev containing stable names for all devices needed, as
          import may fail if device nodes are renamed concurrently with a device failing.
        '';
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
         postDeviceCommands = concatStringsSep "\n" ([''
            ZFS_FORCE="${optionalString cfgZfs.forceImportRoot "-f"}"

            for o in $(cat /proc/cmdline); do
              case $o in
                zfs_force|zfs_force=1)
                  ZFS_FORCE="-f"
                  ;;
              esac
            done
          ''] ++ [ importLibInstance ] ++ (map (pool: ''
            echo -n "importing root ZFS pool \"${pool}\"..."
            # Loop across the import until it succeeds, because the devices needed may not be discovered yet.
            if ! poolImported "${pool}"; then
              for trial in `seq 1 60`; do
                poolReady "${pool}" > /dev/null && msg="$(poolImport "${pool}" 2>&1)" && break
                sleep 1
                echo -n .
              done
              echo
              if [[ -n "$msg" ]]; then
                echo "$msg";
              fi
              poolImported "${pool}" || poolImport "${pool}"  # Try one last time, e.g. to import a degraded pool.
              poolImported "${pool}" || fail "Unable to import pool"
            fi
         '') rootPools));
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
