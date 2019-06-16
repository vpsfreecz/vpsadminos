# Pools
ZFS pools in vpsAdminOS are configured declaratively in Nix configuration, for
example in `os/configs/local.nix`.


# Example configuration
The available configuration options are demonstrated on an example configuration
with 2 HDDs for storage (*sda*, *sdb*) and 2 SSDs for caches and logs
(*sdc*, *sdd*). To try this out in a VM, set:

```nix
boot.qemu.disks = [
  { device = "sda.img"; type = "file"; size = "4G"; create = true; }
  { device = "sdb.img"; type = "file"; size = "4G"; create = true; }
  { device = "sdc.img"; type = "file"; size = "4G"; create = true; }
  { device = "sdd.img"; type = "file"; size = "4G"; create = true; }
]
```

The four devices will be created as files in `os/` when you start the VM later
using `make qemu`.

Pool `tank` could then be defined like the following:

```nix
boot.zfs.pools.tank = {
  # Wipe all disks before zpool create, this will destroy old partition tables
  wipe = [ "sda" "sdb" "sdc" "sdd" ];

  # Partition the SSDs, so that each has one partition for L2ARC and SLOG
  partition = {
    sdc = {
      p1 = { sizeGB=3; };
      p2 = { sizeGB=1; };
    };
    sdd = {
      p1 = { sizeGB=3; };
      p2 = { sizeGB=1; };
    };
  };

  # Pool layout passed to zpool create
  layout = [
    { vdev = "mirror"; devices = [ "sda" "sdb" ]; }
  ];

  # Devices for secondary read cache (L2ARC)
  cache = [ "sdc1" "sdd1" ];

  # Devices for ZFS Intent Log (ZIL)
  log = { mirror = true; devices = [ "sdc2" "sdd2"]; };

  # zpool properties, see man zpool(8)
  properties = {
    comment = "my pool";
  };

  # Once created, install the pool into osctld
  install = true;

  # Do NOT create the pool automatically on boot (this is the default)
  doCreate = false;
};
```

For every defined pool, a runit service `pool-<name>` is generated. The service
tries to import the pool and mounts its datasets. If the pool fails to import
and `doCreate = true`, then the pool is created: disks are wiped, partitioned
and finally zpool create is run. Since an already existing pool can fail to
import due to unforeseen circumstances, it is not recommended to enable
`doCreate`. The pool can be created manually at any time from the configured
layout, see below.

If `install = true`, the pool is imported into *osctld*, which will autostart
configured containers.

## Creating the pool manually
For every defined pool, there is a generated script that you can call to create
the pool manually:

```bash
do-create-pool-tank
WARNING: this program creates zpool tank and may destroy existing
data on configured disks in the process. Use at own risk!

Disks to wipe:
  sda sdb sdc sdd

Disks to partition:
  sdc sdd

zpool to create:
  zpool create -o "comment=my pool" tank mirror sda sdb
  zpool add tank log mirror sdc2 sdd2
  zpool add tank cache sdc1 sdd1

Write uppercase 'yes' to continue:
```

Unless you use switch `-f`, `--force`, the script will ask on standard input for
confirmation before actually creating the pool.

```bash
Write uppercase 'yes' to continue: YES

Wiping disks
[...]

Partitioning disks
[...]

Creating pool "tank"
Adding logs
Adding caches
```

The result can be reviewed by `zpool status`:

```bash
[root@vpsadminos:~]# zpool status
  pool: tank
 state: ONLINE
  scan: none requested
config:

        NAME        STATE     READ WRITE CKSUM
        tank        ONLINE       0     0     0
          mirror-0  ONLINE       0     0     0
            sda     ONLINE       0     0     0
            sdb     ONLINE       0     0     0
        logs
          sdc2      ONLINE       0     0     0
          sdd2      ONLINE       0     0     0
        cache
          sdc1      ONLINE       0     0     0
          sdd1      ONLINE       0     0     0

errors: No known data errors
```

## Declarative pool structure
Datasets and properties can be configured either manually after the pool is
imported, or it is possible to define them within the configuration.
For example:

```nix
boot.zfs.pools.tank = {
  datasets = {
    "/" = {
      properties = {
        compression = "on";
        acltype = "posixacl";
        sharenfs = "on";
      };
    };

    "backup/alfa".properties.quota = "10G";
    "backup/beta".properties.quota = "20G";

    "myvolume" = {
      type = "volume";
      properties.volsize = "5G";
    };
  };
};
```

Dataset names are relative to the pool and optionally may start with a slash.
Two kinds of datasets are supported: `filesystem` (the default) and `volume`.
The ZFS properties are passed directly to ZFS, see man zfs(8) for more
information.

The datasets are created and configured by the runit service. No dataset is
ever destroyed and properties removed from the configuration are not unset
once deployed. To reset a property, set its value to `inherit`.

## Monitoring import progress
Large pools can take several minutes to import and mount all datasets.
The progress can be monitored either in `/var/log/pool-<nam>/current` or
in syslog.

```bash
cat /var/log/pool-tank/current
2018-09-08_08:50:27.42316 Importing ZFS pool "tank"
2018-09-08_08:50:28.40121 Mounting datasets...
2018-09-08_08:50:28.44760 [1/6] Mounting tank
2018-09-08_08:50:28.51206 [2/6] Mounting tank/conf
2018-09-08_08:50:28.54664 [3/6] Mounting tank/ct
2018-09-08_08:50:28.56254 [4/6] Mounting tank/hook
2018-09-08_08:50:28.57755 [5/6] Mounting tank/log
2018-09-08_08:50:28.59338 [6/6] Mounting tank/repository
```

## Periodic scrubs
All ZFS pools should be periodically scrubbed to protect data from silent
corruption. By default, `os/configs/common.nix` enables scrubbing of all
imported pools every 14 days. As in NixOS, scrubbing can be configured
via option `services.zfs.autoScrub`. The default looks as:

```nix
services.zfs.autoScrub = {
  enable = true;
  interval = "0 4 */14 * *"; # date time format for cron (NixOS uses systemd calendar format)
  pools = [];                # scrub all pools
};
```
