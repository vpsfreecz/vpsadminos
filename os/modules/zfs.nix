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
  enableAutoScrub = cfgScrub.enable;

  kernel = config.boot.kernelPackages;

  packages = {
    spl = kernel.spl;
    zfs = kernel.zfs;
    zfsUser = pkgs.zfs;
  };

  osctl = "${pkgs.osctl}/bin/osctl";

  partitioningSupport = elem true (mapAttrsToList (name: pool:
    pool.partition != []
  ) config.boot.zfs.pools);

  doWipe = concatMapStringsSep "\n" (d: ''
    dd if=/dev/zero of=/dev/${d} count=1024
    sectors="$( sfdisk -l /dev/${d} | egrep -o "([[:digit:]]+) sectors" | cut -d' ' -f1 )"
    dd if=/dev/zero of=/dev/${d} seek="$(( $sectors - 1024 ))" count=1024
  '');

  doPartition =
    let
      toSectorSize = x: if x == null then "" else "size=${toString (x * 2048 * 1024)},";
      mkParts = x: concatStrings (intersperse "\n" (mapAttrsToList (n: v: "${replaceStrings ["p"] [""] n}:${toSectorSize v.sizeGB}type=${v.type}") x));
    in
      x: concatStrings (mapAttrsToList (k: v: "echo '${mkParts v};' | sfdisk /dev/${k}\n") x);

  poolService = name: pool: {
    run = ''
      zpool list ${name} > /dev/null

      if [ "$?" != "0" ] ; then
        echo "Importing ZFS pool \"${name}\""
        zpool import -N ${name}

        if [ "$?" != "0" ] ; then
          ${if pool.doCreate then ''
            ${zpoolCreateScript name pool}/bin/do-create-pool-${name} --force || exit 1
          '' else "exit 1"}
        fi
      fi

      stat="$( zpool status ${name} )"
      test $? && echo "$stat" | grep DEGRADED &> /dev/null && \
        echo -e "\n\n[1;31m>>> Pool is DEGRADED!! <<<[0m"

      echo "Mounting datasets..."
      datasets="$(zfs list -Hr -t filesystem -o name,canmount,mounted ${name} \
        | grep $'\ton' `# canmount=on` \
        | grep $'\tno' `# mounted=no` \
        | awk '{ print $1; }')"
      count=$(echo "$datasets" | wc -l)
      i=1

      for ds in $datasets ; do
        echo "[''${i}/''${count}] Mounting $ds"
        zfs mount $ds
        i=$(($i+1))
      done

      active=$(zfs get -Hp -o value org.vpsadminos.osctl:active ${name})

      if [ "$active" == "yes" ] ; then
        ${osctl} pool show -o name ${name} &> /dev/null \
          || ${osctl} pool import ${name} \
          || exit 1

      elif ${if pool.install then "true" else "false"} ; then
        ${osctl} pool install ${name} || exit 1
      fi

      ${optionalString (hasAttr name config.osctl.pools) ''
      echo "Configuring osctl pool"
      ${osctl} pool set parallel-start ${name} ${toString config.osctl.pools.${name}.parallelStart}
      ${osctl} pool set parallel-stop ${name} ${toString config.osctl.pools.${name}.parallelStop}
      ''}

      ${optionalString config.services.nfs.server.enable ''
      echo "Sharing datasets..."
      sv check nfsd > /dev/null || exit 1

      datasets="$(zfs list -Hr -t filesystem -o name,mounted,sharenfs ${name} \
        | grep $'\tyes' `# mounted=yes` \
        | grep -v $'\toff' `# sharenfs!=off` \
        | awk '{ print $1; }')"
      count=$(echo "$datasets" | wc -l)
      i=1

      for ds in $datasets ; do
        echo "[''${i}/''${count}] Sharing $ds"
        zfs share $ds
        i=$(($i+1))
      done
      ''}

      # TODO: this could be option runit.services.<service>.autoRestart = always/on-failure;
      sv once pool-${name}
    '';

    log.enable = true;
    log.sendTo = "127.0.0.1";
  };

  zpoolCreateScript = name: pool: pkgs.writeScriptBin "do-create-pool-${name}" ''
    #!/bin/sh
    if [ "$1" != "-f" ] && [ "$1" != "--force" ] ; then
      echo "WARNING: this program creates zpool ${name} and may destroy existing"
      echo "data on configured disks in the process. Use at own risk!"
      echo

      ${optionalString (pool.wipe != []) ''
        echo "Disks to wipe:"
        echo "  ${concatStringsSep " " pool.wipe}"
        echo
      ''}

      ${optionalString (pool.partition != {}) ''
        echo "Disks to partition:"
        echo "  ${concatStringsSep " " (mapAttrsToList (disk: _: disk) pool.partition)}"
        echo
      ''}

      echo "zpool to create:"
      echo "  zpool create ${name} ${pool.layout}"
      ${optionalString (pool.logs != "") ''
        echo "  zpool add ${name} log ${pool.logs}"
      ''}
      ${optionalString (pool.caches != "") ''
        echo "  zpool add ${name} cache ${pool.caches}"
      ''}
      echo

      read -p "Write uppercase 'yes' to continue: " input
      if [ "$input" != "YES" ] ; then
        echo "Aborting"
        exit 1
      fi
    fi

    ${optionalString (pool.wipe != []) ''
      echo "Wiping disks"
      ${doWipe pool.wipe}
    ''}

    ${optionalString (pool.partition != {}) ''
      echo "Partitioning disks"
      ${doPartition pool.partition}
    ''}

    echo "Creating pool \"${name}\""
    zpool create ${name} ${pool.layout} || exit 1

    ${optionalString (pool.logs != "") ''
      echo "Adding logs"
      zpool add ${name} log ${pool.logs} || exit 1
    ''}

    ${optionalString (pool.caches != "") ''
      echo "Adding caches"
      zpool add ${name} cache ${pool.caches} || exit 1
    ''}
  '';

  zpoolCreateScripts = mapAttrsToList zpoolCreateScript;

  pools = {
    options = {
      layout = mkOption {
        type = types.str;
        default = "# specify layout with boot.zfs.pools.<pool>.layout";
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
