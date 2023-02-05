{ config, lib, pkgs, utils, ... }@args:
#
# todo:
#   - crontab for scrubs, etc
#   - zfs tunables

with utils;
with lib;

let

  moduleRuntimeConfigContent = module: moduleParams:
    let
      val = v: if v == false then "0" else toString v;
      f = k: "/sys/module/${module}/parameters/${k}";
    in
      concatStrings (mapAttrsToList (n: v:
        optionalString (v != null) ''
          if [ "`cat ${f n}`" != "${val v}" ]; then
            echo ${val v} > ${f n};
          fi || true;
        '') moduleParams);

  moduleModprobeConfigContent = name: optionsAttr:
    "options ${name}" +
      concatStrings (mapAttrsToList (n: v:
        optionalString (v != null)
          " ${n}=${if v == false then "0" else toString v}"
      ) optionsAttr) + "\n";

  cfgZfs = config.boot.zfs;
  cfgScrub = config.services.zfs.autoScrub;
  cfgZED = config.services.zfs.zed;
  cfgVdevLog = config.services.zfs.vdevlog;

  inInitrd = any (fs: fs == "zfs") config.boot.initrd.supportedFilesystems;
  inSystem = any (fs: fs == "zfs") config.boot.supportedFilesystems;

  enableZfs = inInitrd || inSystem;
  enableAutoScrub = cfgScrub.enable;

  kernel = config.boot.kernelPackages;

  packages = {
    zfs = kernel.zfs;
    zfsUser = config.boot.zfsUserPackage;
  };

  partitioningSupport = elem true (mapAttrsToList (name: pool:
    pool.partition != {}
  ) config.boot.zfs.pools);

  zfsFilesystems = filter (x: x.fsType == "zfs") config.system.build.fileSystems;

  datasetToPool = x: elemAt (splitString "/" x) 0;

  fsToPool = fs: datasetToPool fs.device;

  rootPools = unique (map fsToPool (filter fsNeededForBoot zfsFilesystems));

  # safe import of ZFS pool
  # according to https://github.com/NixOS/nixpkgs/commit/cfd8c4ee88fec3a7f989663e09d8e39513b8488e
  importLib = { cfgZfs }:
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
        zpool list "$pool" >/dev/null 2>/dev/null
      }
      poolImport() {
        pool="$1"
        zpool import ${devOptions} -N $ZFS_FORCE "$pool"
      }
    '';

  poolService = name: pool: (import ./pool-service.nix args) {
    inherit name pool zpoolCreateScript packages;
    importLib = importLib { inherit cfgZfs; };
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
    zpool = "zpool";
  };

  zpoolCreateScripts = mapAttrsToList zpoolCreateScript;

  autoScrubZpools =
    if cfgScrub.pools == [] then
      "$(${packages.zfsUser}/bin/zpool list -H -o name)"
    else
      concatStringsSep " " cfgScrub.pools;

  autoScrubJobs = optionals enableAutoScrub (flatten [
    (map (i: "${i} root ${pkgs.scrubctl}/bin/scrubctl start ${autoScrubZpools}") cfgScrub.startIntervals)
    (map (i: "${i} root ${pkgs.scrubctl}/bin/scrubctl pause ${autoScrubZpools}") cfgScrub.pauseIntervals)
    (map (i: "${i} root ${pkgs.scrubctl}/bin/scrubctl resume ${autoScrubZpools}") cfgScrub.resumeIntervals)
  ]);

  zpoolsToScrub = filterAttrs (name: pool: pool.scrub.enable) cfgZfs.pools;

  zpoolScrubCommand = name: pool: action: userCmd:
    if isNull userCmd then
      "${pkgs.scrubctl}/bin/scrubctl ${action} ${name}"
    else
      userCmd;

  perZpoolJobs =
    flatten ((mapAttrsToList (name: pool: flatten ([
      (map (i: "${i} root ${zpoolScrubCommand name pool "start" pool.scrub.startCommand}") pool.scrub.startIntervals)
      (map (i: "${i} root ${zpoolScrubCommand name pool "pause" pool.scrub.pauseCommand}") pool.scrub.pauseIntervals)
      (map (i: "${i} root ${zpoolScrubCommand name pool "resume" pool.scrub.resumeCommand}") pool.scrub.resumeIntervals)
    ])) zpoolsToScrub));

  perZpoolAssertions =
    mapAttrsToList (name: pool: {
      assertion = !pool.scrub.enable || pool.scrub.startIntervals != [];
      message = "Set boot.zfs.pools.${name}.scrub.startIntervals or disable boot.zfs.pools.${name}.scrub.enable";
    }) zpoolsToScrub;

  zedConf = generators.toKeyValue {
    mkKeyValue = generators.mkKeyValueDefault {
      mkValueString = v:
        if isInt           v then toString v
        else if isString   v then "\"${v}\""
        else if true  ==   v then "1"
        else if false ==   v then "0"
        else if isList     v then "\"" + (concatStringsSep " " v) + "\""
        else err "this value is" (toString v);
    } "=";
  } cfgZED.settings;

  makeZedlet = name: zedlet:
    if isNull zedlet.script then
      { inherit (zedlet) enable source; }
    else {
      inherit (zedlet) enable;
      source = pkgs.writeScript "zedlet-${name}" zedlet.script;
    };

  makeZedlets = mapAttrs' (k: v: nameValuePair "zfs/zed.d/${k}" (makeZedlet k v)) cfgZED.zedlets;

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

  moduleParam = mkOptionType {
    name = "module option value";
    check = val:
      let
        checkType = x: isBool x || isString x || isInt x || x == null;
      in
        checkType val || (val._type or "" == "override" && checkType val.content);
    merge = loc: defs: mergeOneOption loc (filterOverrides defs);
  };
  moduleParams = {
    options = {
      spl = mkOption {
        default = {};
        example = literalExpression ''
          { "spl_taskq_thread_priority" = true; "spl_taskq_thread_sequential" = 2; }
        '';
        type = types.attrsOf moduleParam;
        description = ''
          spl module load time options
        '';
      };
      zfs = mkOption {
        default = {};
        example = literalExpression ''
          { "zfs_arc_min" = 1073741824; }
        '';
        type = types.attrsOf moduleParam;
        description = ''
          zfs module load time options
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

      importAttempts = mkOption {
        type = types.addCheck types.int (x: x >= 3) // {
          name = "importAttempts";
          description = "3 or more";
        };
        default = 60;
        description = ''
          Number of attempts to cleanly import the pool with all devices present.
          After the attempts are spent, even a degraded pool will be imported.
          If the pool still can't be imported, the service will either fail
          or create the pool if option
          <option>boot.zfs.pools.&lt;name&gt;.doCreate</option> is enabled.
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
        default = {
          "/" = {
            properties = {
              xattr = mkDefault "sa";
            };
          };
        };
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

      scrub = {
        enable = mkOption {
          default = false;
          type = types.bool;
          description = ''
            Enables periodic scrubbing
          '';
        };

        startIntervals = mkOption {
          default = [];
          type = types.listOf types.str;
          description = ''
            Date and time expression for when to scrub the pool in a crontab
            format, i.e. minute, hour, day of month, month and day of month
            separated by spaces.
          '';
        };

        pauseIntervals = mkOption {
          default = [];
          type = types.listOf types.str;
          description = ''
            Date and time expression for when to pause a running scrub in a crontab
            format, i.e. minute, hour, day of month, month and day of month
            separated by spaces.
          '';
        };

        resumeIntervals = mkOption {
          default = [];
          type = types.listOf types.str;
          description = ''
            Date and time expression for when to resume a paused scrub in a crontab
            format, i.e. minute, hour, day of month, month and day of month
            separated by spaces.
          '';
        };

        startCommand = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Optionally override the auto-generated command used to scrub
            the pool.

            Defaults to <literal>scrubctl start &lt;pool&gt;</literal>.
          '';
        };

        pauseCommand = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Optionally override the auto-generated command used to pause scrub
            of the pool.

            Defaults to <literal>scrubctl pause &lt;pool&gt;</literal>.
          '';
        };

        resumeCommand = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Optionally override the auto-generated command used to resume scrub
            of the pool.

            Defaults to <literal>scrubctl resume &lt;pool&gt;</literal>.
          '';
        };
      };
    };
  };

  zedletModule =
    { config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Enable the ZEDLET
          '';
        };

        script = mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = ''
            Script invoked by the ZEDLET, must include shebang
          '';
        };

        source = mkOption {
          type = types.path;
          description = ''
            Executable called by ZED
          '';
        };
      };
    };

in

{

  ###### interface

  options = {
    boot.zfs = {
      moduleParams = mkOption {
        type = types.submodule moduleParams;
        default = {};
      };

      pools = mkOption {
        type = types.attrsOf (types.submodule pools);
        default = {};
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

      startIntervals = mkOption {
        default = [];
        type = types.listOf types.str;
        description = ''
          Date and time expression for when to scrub the pool in a crontab
          format, i.e. minute, hour, day of month, month and day of month
          separated by spaces.
        '';
      };

      pauseIntervals = mkOption {
        default = [];
        type = types.listOf types.str;
        description = ''
          Date and time expression for when to pause a running scrub in a crontab
          format, i.e. minute, hour, day of month, month and day of month
          separated by spaces.
        '';
      };

      resumeIntervals = mkOption {
        default = [];
        type = types.listOf types.str;
        description = ''
          Date and time expression for when to resume a paused scrub in a crontab
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

    services.zfs.zed = {
      zedlets = mkOption {
        type = types.attrsOf (types.submodule zedletModule);
        default = {};
        description = ''
          ZEDLET executable to install to /etc/zfs/zed.d, see man zed(8)
        '';
      };

      settings = mkOption {
        type = with types; attrsOf (oneOf [ str int bool (listOf str) ]);
        example = literalExpression ''
          {
            ZED_DEBUG_LOG = "/tmp/zed.debug.log";
            ZED_EMAIL_ADDR = [ "root" ];
            ZED_EMAIL_PROG = "mail";
            ZED_EMAIL_OPTS = "-s '@SUBJECT@' @ADDRESS@";
            ZED_NOTIFY_INTERVAL_SECS = 3600;
            ZED_NOTIFY_VERBOSE = false;
            ZED_USE_ENCLOSURE_LEDS = true;
            ZED_SCRUB_AFTER_RESILVER = false;
          }
        '';
        description = lib.mdDoc ''
          ZFS Event Daemon /etc/zfs/zed.d/zed.rc content
          See
          {manpage}`zed(8)`
          for details on ZED and the scripts in /etc/zfs/zed.d to find the possible variables
        '';
      };
    };

    services.zfs.vdevlog = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable vdevlog, a service which keeps persistent track of vdev errors
        '';
      };

      metricsDirectory = mkOption {
        type = types.nullOr types.str;
        default = "/run/metrics";
        description = ''
          Directory where file with prometheus metrics will be stored
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

      boot.extraModprobeConfig = "\n" +
        optionalString (cfgZfs.moduleParams.spl != {}) (moduleModprobeConfigContent "spl" cfgZfs.moduleParams.spl + "\n") +
        optionalString (cfgZfs.moduleParams.zfs != {}) (moduleModprobeConfigContent "zfs" cfgZfs.moduleParams.zfs + "\n");

      boot.initrd = mkIf inInitrd {
        kernelModules = [ "zfs" ];
        extraUtilsCommands =
          ''
            copy_bin_and_libs ${packages.zfsUser}/sbin/zfs
            copy_bin_and_libs ${packages.zfsUser}/sbin/zdb
            copy_bin_and_libs ${packages.zfsUser}/sbin/zpool
            ${optionalString partitioningSupport ''
              copy_bin_and_libs ${pkgs.util-linux}/bin/sfdisk
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
          ''] ++ [ (importLib {
            inherit cfgZfs;
          }) ] ++ (map (pool: ''
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

      boot.loader.grub = mkIf (inInitrd || inSystem) {
        zfsSupport = true;
      };

      services.udev.packages = [ packages.zfsUser ];

      runit.services = mkMerge [
        (mapAttrs' (name: pool:
          nameValuePair "pool-${name}" (poolService name pool))
          cfgZfs.pools)

        {
          spl-module-parameters = {
            run =
              moduleRuntimeConfigContent "spl" cfgZfs.moduleParams.spl + "\n" +
              "sleep inf";
            finish = "";
            runlevels = [ "default" ];
          };

          zfs-module-parameters = {
            run =
              moduleRuntimeConfigContent "zfs" cfgZfs.moduleParams.zfs + "\n" +
              "sleep inf";
            finish = "";
            runlevels = [ "default" ];
          };

          zfs-zed = {
            run = ''
              exec ${packages.zfsUser}/sbin/zed -F
            '';
            runlevels = [ "default" ];
            log.enable = true;
            log.sendTo = "127.0.0.1";
          };
        }
      ];

      services.zfs.zed.settings = {
        PATH = lib.makeBinPath [
          packages.zfsUser
          pkgs.coreutils
          pkgs.curl
          pkgs.eudev
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.nettools
          pkgs.util-linux
        ];
      };

      environment.etc = genAttrs
        (map
          (file: "zfs/zed.d/${file}")
          [
            "all-syslog.sh"
            "pool_import-led.sh"
            "resilver_finish-start-scrub.sh"
            "statechange-led.sh"
            "vdev_attach-led.sh"
            "zed-functions.sh"
            "data-notify.sh"
            "resilver_finish-notify.sh"
            "scrub_finish-notify.sh"
            "statechange-notify.sh"
            "vdev_clear-led.sh"
          ]
        )
        (file: { source = "${packages.zfsUser}/etc/${file}"; })
      // {
        "zfs/zed.d/zed.rc".text = zedConf;
        "zfs/zpool.d".source = "${packages.zfsUser}/etc/zfs/zpool.d/";
      } // makeZedlets;

      system.fsPackages = [ packages.zfsUser ]; # XXX: needed? zfs doesn't have (need) a fsck
      environment.systemPackages = [ packages.zfsUser ] ++ (zpoolCreateScripts cfgZfs.pools);
    })

    (mkIf cfgVdevLog.enable {
      environment.systemPackages = with pkgs; [ vdevlog ];

      services.zfs.zed = {
        zedlets.io-vdevlog.script = ''
          #!${pkgs.bash}/bin/bash
          . /etc/zfs/zed.d/zed.rc
          export PATH
          exec ${pkgs.vdevlog}/bin/vdevlog
        '';
      };

      services.cron.systemCronJobs = [
        "33 */1 * * * root ${pkgs.vdevlog}/bin/vdevlog -u"
      ];
    })

    {
      assertions = [
        {
          assertion = !cfgScrub.enable || cfgScrub.startIntervals != [];
          message = "Set services.zfs.autoScrub.startIntervals or disable services.zfs.autoScrub.enable";
        }
      ] ++ perZpoolAssertions;

      services.cron.systemCronJobs = autoScrubJobs ++ perZpoolJobs;
    }
  ];
}
