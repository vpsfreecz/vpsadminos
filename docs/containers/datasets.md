# Datasets
Every container resides in its own ZFS dataset, where its root file system
is stored. Name of that dataset can be obtained using `osctl ct ls`:

```shell
osctl ct ls -o dataset,rootfs myct01
DATASET          ROOTFS                  
tank/ct/myct01   /tank/ct/myct01/private
```

Notice that `ROOTFS` is not directly in the dataset's mountpoint, i.e.
`/tank/ct/myct01`. This is to ensure that the container does not have access
to the `.zfs` special directory, which could be used to manipulate snapshots
from within the container.

## Impermanent NixOS roots

On a normal start, an impermanent NixOS container gets a new temporary dataset
named `<base-dataset>.impermanence-<suffix>`. Its root filesystem is the
temporary dataset's `private` directory. The supplied impermanence images keep
persistent data on the base dataset mounted at `/persistent`; see
[NixOS guests](nixos.md) for guest configuration.

Enabling impermanence on an already-running container does not replace its
current root. It uses the temporary root on its next normal start.

The runtime configuration records the selected dataset, run identity and cleanup
policy before the workload starts, independently of CPU scheduler assignment.
Replacing osctld or activating another userspace generation preserves that run,
its mounts and temporary data. A normal container restart creates a new temporary
root while retaining persistent backing data.

The container's mount namespace can show `/private` as the root of the ZFS mount
at `/`, including an idmapped bind mount. Its dataset mountpoint and live root
are different directories. A recovery check must identify the live root through
the container init process and match the dataset's `private` directory; a host
mount prefix or a matching pathname alone does not establish ownership.

See [updates](../os/updates.md#running-impermanent-containers) for importing
containers whose saved runtime selection came from an older daemon.

## Subdatasets
*osctld* also supports subdatasets, which can be used to logically divide data
or provide specific configuration of ZFS properties. Subdatasets can be created
using the *zfs* command-line utility, but you'd have to mount them manually,
What's worse, *osctld* wouldn't be able to ensure that your mounts would
work after container export/import or send to another vpsAdminOS node,
which may have different pool paths. This is the reason why *osctl* has commands
for manipulating container subdatasets.

Container's datasets can be listed with `osctl ct dataset ls`:

```shell
osctl ct dataset ls myct01
NAME   DATASET        
/      tank/ct/myct01
```

`NAME` is relative to the container's dataset, and in case of the container's
root dataset, it is `/`. `DATASET` is the dataset's full name, as ZFS knows it.
Let's create a subdataset:

```shell
osctl ct dataset new myct01 srv/data

osctl ct dataset ls myct01
NAME       DATASET                 
/          tank/ct/myct01          
srv        tank/ct/myct01/srv      
srv/data   tank/ct/myct01/srv/data
```

As you can see, you can create nested subdatasets, all non-existing parents will
be created, i.e. in this case `srv` and then `srv/data`. The datasets were also
automatically mounted into the container:

```shell
osctl ct mount ls myct01
FS                                 DATASET    MOUNTPOINT   TYPE   OPTS               
/tank/ct/myct01/srv/private        srv        /srv         bind   bind,rw,create=dir 
/tank/ct/myct01/srv/data/private   srv/data   /srv/data    bind   bind,rw,create=dir
```

*osctld* is tracking the mount-dataset relation, so that when you remove a dataset,
corresponding mounts are either unmounted, or the removal fails. Datasets are
automatically mounted under their parent dataset's mountpoint. For example,
the parent of `srv` is `/`, so `srv` will be mounted to `/srv`. `srv` is the
parent of `srv/data`, which means that `srv/data` will be mounted to `/srv/data`.

The target mountpoint can be overriden using an optional argument:

```shell
osctl ct dataset new myct01 srv/www /var/www
osctl ct mount ls myct01
FS                                 DATASET    MOUNTPOINT   TYPE   OPTS               
/tank/ct/myct01/srv/private        srv        /srv         bind   bind,rw,create=dir 
/tank/ct/myct01/srv/data/private   srv/data   /srv/data    bind   bind,rw,create=dir 
/tank/ct/myct01/srv/www/private    srv/www    /var/www     bind   bind,rw,create=dir
```

Subdatasets are automatically shifted into the container's user namespace:

```shell
zfs list -r -oname,uidmap,gidmap tank/ct/myct01
NAME                     UIDMAP          GIDMAP
tank/ct/myct01           0:666000:65536  0:666000:65536
tank/ct/myct01/srv       0:666000:65536  0:666000:65536
tank/ct/myct01/srv/data  0:666000:65536  0:666000:65536
tank/ct/myct01/srv/www   0:666000:65536  0:666000:65536
```

All container's subdatasets are considered an integral part of the container,
i.e. they are exported or sent together with the container. For this reason,
it is not recommended to cross-mount subdatasets of one container to another
container, as you would have to maintain that dependency on your own.

## Using ZFS
Subdatasets can be created directly using ZFS, but they won't be automatically
mounted into the container:

```shell
# Create the dataset
zfs create tank/ct/myct01/custom

# osctld will see it immediately
osctl ct dataset ls myct01
NAME       DATASET                 
/          tank/ct/myct01          
custom     tank/ct/myct01/custom   
srv        tank/ct/myct01/srv      
srv/data   tank/ct/myct01/srv/data 
srv/www    tank/ct/myct01/srv/www  

# No mountpoint is created
osctl ct mount ls myct01
FS                                 DATASET    MOUNTPOINT   TYPE   OPTS               
/tank/ct/myct01/srv/private        srv        /srv         bind   bind,rw,create=dir 
/tank/ct/myct01/srv/data/private   srv/data   /srv/data    bind   bind,rw,create=dir 
/tank/ct/myct01/srv/www/private    srv/www    /var/www     bind   bind,rw,create=dir 

# Because uidmap/gidmap properties are inherited, the subdataset is shifted
# into the container's user namespace
zfs list -r -oname,uidmap,gidmap tank/ct/myct01
NAME                     UIDMAP          GIDMAP
tank/ct/myct01           0:666000:65536  0:666000:65536
tank/ct/myct01/custom    0:666000:65536  0:666000:65536
tank/ct/myct01/srv       0:666000:65536  0:666000:65536
tank/ct/myct01/srv/data  0:666000:65536  0:666000:65536
tank/ct/myct01/srv/www   0:666000:65536  0:666000:65536
```

## Mounting datasets
Subdatasets can be mounted at any time using `osctl ct mount dataset`. While they
could also be mounted using `osctl ct mount new`, they wouldn't be tracked
as a subdataset mount, which could prevent successful container export/import
or send, as mentioned above.

```shell
osctl ct mount dataset myct01 custom /mnt/custom

osctl ct mount ls myct01
FS                                 DATASET    MOUNTPOINT    TYPE   OPTS               
/tank/ct/myct01/srv/private        srv        /srv          bind   bind,rw,create=dir 
/tank/ct/myct01/srv/data/private   srv/data   /srv/data     bind   bind,rw,create=dir 
/tank/ct/myct01/srv/www/private    srv/www    /var/www      bind   bind,rw,create=dir 
/tank/ct/myct01/custom/private     custom     /mnt/custom   bind   bind,rw,create=dir
```

Notice that when interacting with *osctl*, you always use the dataset's relative
name to the container's root dataset, not its full name.

## Removing subdatasets
The root dataset cannot be deleted while the container exists, but subdatasets
can be deleted using `osctl ct dataset del`. It essentially calls `zfs destroy`,
but first it checks that the dataset is not mounted, or that the mounts can
be unmounted. Without any options, a mounted dataset cannot be deleted:

```shell
osctl ct dataset del myct01 custom
error: the following mountpoints need to be unmounted:
  /mnt/custom
```

Using option `-u`, `--unmount`, all relevant mounts are unmounted:

```shell
osctl ct dataset del --unmount myct01 custom
```

Another safe-check is that by default, a dataset cannot be deleted, if it has
children:

```shell
osctl ct dataset del myct01 srv   
error: dataset has children, recursive delete has to be enabled explicitly
```

Option `-r`, `--recursive` can be used to delete the dataset with all its
children, exactly like `zfs destroy -r` does:

```shell
osctl ct dataset del -r myct01 srv
error: the following mountpoints need to be unmounted:
  /var/www
  /srv/data
  /srv
```

Except the datasets are still mounted, so add `--unmount` as well:

```shell
osctl ct dataset del --recursive --unmount myct01 srv
```
