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
    spl = kernel.splUnstable;
    zfs = kernel.zfsUnstable;
    zfsUser = pkgs.zfsUnstable;
  };

  datasetToPool = x: elemAt (splitString "/" x) 0;

  fsToPool = fs: datasetToPool fs.device;

  zfsFilesystems = filter (x: x.fsType == "zfs") config.system.build.fileSystems;

  allPools = unique ((map fsToPool zfsFilesystems) ++ cfgZfs.extraPools);

  rootPools = unique (map fsToPool (filter fsNeededForBoot zfsFilesystems));

  dataPools = unique (filter (pool: !(elem pool rootPools)) allPools);

  snapshotNames = [ "frequent" "hourly" "daily" "weekly" "monthly" ];

in

{

  ###### interface

  options = {
    boot.zfs = {
      extraPools = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "tank" "data" ];
        description = ''
          Name or GUID of extra ZFS pools that you wish to import during boot.

          Usually this is not necessary. Instead, you should set the mountpoint property
          of ZFS filesystems to <literal>legacy</literal> and add the ZFS filesystems to
          NixOS's <option>fileSystems</option> option, which makes NixOS automatically
          import the associated pool.

          However, in some cases (e.g. if you have many filesystems) it may be preferable
          to exclusively use ZFS commands to manage filesystems. If so, since NixOS/systemd
          will not be managing those filesystems, you will need to specify the ZFS pool here
          so that NixOS automatically imports it on every boot.
        '';
      };

      devNodes = mkOption {
        type = types.path;
        default = "/dev/disk/by-id";
        example = "/dev/disk/by-id";
        description = ''
          Name of directory from which to import ZFS devices.

          This should be a path under /dev containing stable names for all devices needed, as
          import may fail if device nodes are renamed concurrently with a device failing.
        '';
      };

      forceImportRoot = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Forcibly import the ZFS root pool(s) during early boot.

          This is enabled by default for backwards compatibility purposes, but it is highly
          recommended to disable this option, as it bypasses some of the safeguards ZFS uses
          to protect your ZFS pools.

          If you set this option to <literal>false</literal> and NixOS subsequently fails to
          boot because it cannot import the root pool, you should boot with the
          <literal>zfs_force=1</literal> option as a kernel parameter (e.g. by manually
          editing the kernel params in grub during boot). You should only need to do this
          once.
        '';
      };

      forceImportAll = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Forcibly import all ZFS pool(s).

          This is enabled by default for backwards compatibility purposes, but it is highly
          recommended to disable this option, as it bypasses some of the safeguards ZFS uses
          to protect your ZFS pools.

          If you set this option to <literal>false</literal> and NixOS subsequently fails to
          import your non-root ZFS pool(s), you should manually import each pool with
          "zpool import -f &lt;pool-name&gt;", and then reboot. You should only need to do
          this once.
        '';
      };
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf enableZfs {
      assertions = [
        {
          assertion = config.networking.hostId != null;
          message = "ZFS requires config.networking.hostId to be set";
        }
        {
          assertion = !cfgZfs.forceImportAll || cfgZfs.forceImportRoot;
          message = "If you enable boot.zfs.forceImportAll, you must also enable boot.zfs.forceImportRoot";
        }
      ];

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
            ZFS_FORCE="${optionalString cfgZfs.forceImportRoot "-f"}"

            for o in $(cat /proc/cmdline); do
              case $o in
                zfs_force|zfs_force=1)
                  ZFS_FORCE="-f"
                  ;;
              esac
            done
            ''] ++ (map (pool: ''
            echo -n "importing root ZFS pool \"${pool}\"..."
            trial=0
            until msg="$(zpool import -d ${cfgZfs.devNodes} -N $ZFS_FORCE '${pool}' 2>&1)"; do
              sleep 0.25
              echo -n .
              trial=$(($trial + 1))
              if [[ $trial -eq 60 ]]; then
                break
              fi
            done
            echo
            if [[ -n "$msg" ]]; then echo "$msg"; fi
        '') rootPools));
      };

      environment.etc."zfs/zed.d".source = "${packages.zfsUser}/etc/zfs/zed.d/";

      system.fsPackages = [ packages.zfsUser ]; # XXX: needed? zfs doesn't have (need) a fsck
      environment.systemPackages = [ packages.zfsUser ];

    })
  ];
}
