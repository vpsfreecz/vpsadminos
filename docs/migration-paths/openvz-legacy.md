# OpenVZ Legacy Converter
The converter is capable of exporting a vpsAdminOS-compatible container image,
or directly migrating OpenVZ containers onto vpsAdminOS nodes, like you would
use `vzmigrate`. The converter supports containers with `simfs` on top of any
file system, `ploop` with `ext4` or containers residing in ZFS datasets.

## Installation
The converter has to be installed on OpenVZ nodes from which you wish to
migrate your containers away. It is distributed as a Ruby gem and can be
installed as such. The only caveat for now is that the converter requires
Ruby newer than 2.0, while OpenVZ Legacy usually has only 1.8.9.

You can install newer Ruby from our repository:

```shell
$ cat <<EOF > /etc/yum.repos.d/vpsfree.repo 
[vpsfree]
name=vpsFree.cz package repository
baseurl=http://repo.vpsfree.cz/stable/
enabled=1
gpgcheck=0

$ yum install ruby
```

After the installation, you can disable the repository. Now you can install
the converter itself:

```shell
$ gem install --source https://rubygems.vpsfree.cz --prerelease vpsadminos-converter libosctl
```

Because Ruby gems cannot install manual pages into the system, the converter
provides its own command, using which you can read its manpage:

```shell
$ vpsadminos-convert man
```

## Exporting
### Simfs/ploop
For `simfs`/`ploop` containers, the converter simply packs the container's
root filesystem into a tarball. If you wish to have the tarball consistent,
which is the default, the container has to be stopped while the exporting takes
place.

To export container `101` into `ct-101.tar`, execute:

```shell
openvz-node $ vpsadminos-convert vz6 export 101 ct-101.tar
```

The exported tarball contains not only the root filesystem, but also relevant
config files converted from OpenVZ into vpsAdminOS.

You can also export the container while it is running, but the data may change
when exporting it, so it is not recommended:

```shell
openvz-node $ vpsadminos-convert vz6 export --no-consistent 101 ct-101.tar
```

### ZFS
If you have your containers stored in ZFS datasets, you are encouraged to signal
this to the converter, because it can export the containers much more efficiently
using ZFS streams. However, only a specific configuration is allowed at the
moment:

 - every container has to be in its own dataset,
 - the container's root filesystem is not in the dataset's root, but in
   a subdirectory called `private`.

This is how [vpsAdmin](https://github.com/vpsfreecz/vpsadmin) creates its
containers and it is the only supported ZFS configuration thus far. Exporting
of ZFS streams is enabled using switch `--zfs`. If you don't provide it,
the container's root filesystem will be packed by tar, even if it resides
in a ZFS dataset.

So, let's consider we have container `101` stored in dataset `vz/private/101`,
with `VE_PRIVATE` set to `/vz/private/101/private`, it can be exported by:

```shell
openvz-node $ vpsadminos-convert vz6 export --zfs \
                                            --zfs-dataset vz/private/101 \
                                            --zfs-subdir private \
                                            101 ct-101.tar
```

The consistent exporting with ZFS also does not stop the container unnecessarily.
When the container is running, a snapshot is taken and dumped, this can take
a long time. Next, the container is stopped, another snapshot is taken and
dumped, which will be much smaller and thus faster.

Another useful ZFS feature is dumping compressed ZFS streams, if you have
compression enabled on your datasets. Because this feature came not long ago
with ZFS on Linux 0.7, it has to be enabled manually using
`--zfs-compressed-send`.

### Configuration
The converter is able to convert the most important parts of the container's
configuration on its own, but still many configuration options from OpenVZ
have no equivalent in vpsAdminOS. The converter will tell you what options were
converted and which were ignored:

```shell
openvz-node $ vpsadminos-convert vz6 export 101 ct-101.tar
Parsing config
Consumed config items:
  PHYSPAGES = [0, 1048576]
  SWAPPAGES = [0, 0]
  NETFILTER = "stateless"
  HOSTNAME = "vps"
  VE_ROOT = "/vz/root/101"
  VE_PRIVATE = "/vz/private/101/private"
  VE_LAYOUT = "simfs"
  OSTEMPLATE = "debian-9.0-amd64-vpsfree"
  IP_ADDRESS = [...]
  NAMESERVER = [...]
  ONBOOT = true

Ignored config items:
  DISKSPACE = "2097152:2306867"
  DISKINODES = "131072:144179"
  QUOTATIME = "0"
  CPUUNITS = 32320
  ORIGIN_SAMPLE = "base-privvmpages"
  KMEMSIZE = "105377561:115915317"
  LOCKEDPAGES = "5145"
  PRIVVMPAGES = "1048576:1585152"
  SHMPAGES = "139818"
  NUMPROC = "2572"
  VMGUARPAGES = "233030:unlimited"
  OOMGUARPAGES = "unlimited"
  NUMTCPSOCK = "2572"
  NUMFLOCK = "1000:1100"
  NUMPTY = "257"
  NUMSIGINFO = "1024"
  TCPSNDBUF = "24590942:35125854"
  TCPRCVBUF = "24590942:35125854"
  OTHERSOCKBUF = "12295471:22830383"
  DGRAMRCVBUF = "12295471"
  NUMOTHERSOCK = "2572"
  NUMFILE = "41152"
  DCACHESIZE = "23013157:23703552"
  NUMIPTENT = "62"
  CPULIMIT = 800
  CPUS = 8
```

As you can see, all user beancounters are ignored. Disk quotas are also
ignored, you have to set appropriate ZFS quotas on your own. CPU limiting is
also not converted, but at least `CPULIMIT` could be converted in the future.
Memory limits are deduced from [vSwap](https://openvz.org/VSwap).

### Networking
The converter can so far work only with [venet](https://openvz.org/Virtual_network_device).
By default, `venet0` from OpenVZ will be `eth0` in vpsAdminOS. It will be
a bridged veth, linked with `lxcbr0`. You have the option to rename the interface,
set MAC address, change the link device or use routed veth instead, see
the [user guide](/user-guide/networking.md) for more information.

To change bridged veth:

```shell
openvz-node $ vpsadminos-convert vz6 export --netif-type bridge \
                                            --netif-name supereth0 \
                                            --netif-hwaddr 00:11:22:33:44:55 \
                                            --bridge-link bestbridge0 \
                                            101 ct-101.tar
```

And for routed veth:

```shell
openvz-node $ vpsadminos-convert vz6 export --netif-type routed \
                                            --netif-name supereth0 \
                                            --netif-hwaddr 00:11:22:33:44:55 \
                                            --route-via 10.100.10.100/30 \ # this is required
                                            101 ct-101.tar
```

## Importing
The exported tarball has to be copied over to vpsAdminOS node by the user and
then imported, like if it were exported by
[osctl ct export](/containers/export_import.md):

```shell
vpsadminos-node $ osctl ct import ct-101.tar
```

## Migration
The converter can migrate the container from OpenVZ nodes into vpsAdminOS nodes,
without dumping it into a file first. The two nodes have to be running at the
same time. Migration can save you some downtime and disk space, it works like
`vzmigrate` from OpenVZ and exactly like `osctl ct migrate` between two vpsAdminOS
nodes. In the worst case scenario, the container will not start on vpsAdminOS,
or will be misconfigured and services won't be available. However, the container
safely remains back on the OpenVZ node, where it can be restarted and another
migration attempt can be made later.

### Preparation
Like with migration between two vpsAdminOS nodes, SSH key authorization has to
be set up. On the OpenVZ node, if you don't already have a key pair for root,
generate it:

```shell
openvz-node $ ssh-keygen
openvz-node $ cat ~/.ssh/id_rsa.pub
<your public key>
```

Then authorize the key on the vpsAdminOS node:

```shell
vpsadminos-node $ osctl migration authorized-keys add
<here you enter the public key>
```

### Migration stages
The migration is split into several steps, exactly like
[osctl ct migrate](/containers/migrations.md) is:
 
 - `vpsadminos-converter vz6 migrate stage` is used to prepare environment on
   the destination node and copy the converted configuration
 - `vpsadminos-converter vz6 migrate sync` sends over the container's rootfs
 - `vpsadminos-converter vz6 migrate transfer` stops the container on the source
   node, performs another rootfs sync and finally starts the container on the
   destination node
 - `vpsadminos-converter vz6 migrate cleanup` is used to reset migration state
   and optionally remove the container from the source node

Up until `vpsadminos-convert vz6 migrate transfer`, the migration can be cancelled
using `vpsadminos-convert vz6 migrate cancel`, which resets the container's
migration state on the source node and removes the partially transfered container
from the destination node.

`vpsadminos-convert vz6 migrate now` will perform all necessary migration steps
in succession. Use this when you don't care when is a particular migration step
run. Otherwise, you can choose when to run specific migration steps to optimize
for minimum downtime at reasonable hours.

### Simfs/ploop
Migration from `simfs`/`ploop` requires some additional configuration, because
the standard migration protocol that `osctld` implements can work only with ZFS
streams. Thus, `simfs`/`ploop` based containers are copied using `rsync`, and
that requires root-to-root connection over SSH. Place the public key you
generated above into `/etc/ssh/authorized_keys.d/root` on the vpsAdminOS node.

To migrate the container in one step, use:

```shell
openvz-node $ vpsadminos-convert vz6 migrate now 101 vpsadminos-node
```

Where `vpsadminos-node` is a resolvable hostname or an IP address. It is given
as-is to SSH, so you might configure the host in your SSH configuration.

`vpsadminos-convert vz6 migrate now` will ask you if you wish to continue with
the migration, after it was successfully staged. You can review the converted
configuration and decide to either continue or cancel the migration.

`vpsadminos-convert vz6 migrate stage` and `vpsadminos-convert vz6 migrate now`
have the same switches for networking configuration conversion as
`vpsadminos-convert vz6 export` does, see [above](#networking).

### ZFS
Migration of containers stored in ZFS datasets has the same restrictions as
exporting of such containers has. If your container fits those conditions, the
migration command looks exactly like exporting does:

```shell
openvz-node $ vpsadminos-convert vz6 migrate now --zfs \
                                                 --zfs-dataset vz/private/101 \
                                                 --zfs-subdir private \
                                                 --zfs-compressed-send \
                                                 101 vpsadminos-node
```
