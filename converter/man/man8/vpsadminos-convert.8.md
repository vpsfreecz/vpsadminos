# vpsadminos-convert 8            2020-05-06                             20.03

## NAME
`vpsadminos-convert` - convert existing containers into vpsAdminOS.

## SYNOPSIS
`vpsadminos-convert` *command* [*command options*] [*arguments...*]

## DESCRIPTION
`vpsadminos-convert` is a tool for converting existing containers into
vpsAdminOS containers. `vpsadminos-convert` can convert standard OpenVZ
containers with `simfs` with arbitrary file system or `ploop` with `ext4`.
It can also efficiently convert containers stored in ZFS datasets, e.g.
containers managed by [vpsAdmin](https://github.com/vpsfreecz/vpsadmin).

## OPENVZ LEGACY COMMANDS
`vpsadminos-convert` can be used to export an OpenVZ container into a tar
archive. The exported archive is then copied to vpsAdminOS node by the user
at his convenience and imported using `osctl ct import` *file*, see osctl(8).
It can also migrate containers to vpsAdminOS nodes directly, similarly to
`vzmigrate` from OpenVZ Legacy.

`vz6 export` [*options*] *ctid* *file*
  Export OpenVZ container *ctid* into a tar archive saved to *file*. By default,
  the container's root filesystem is packed into a tar archive. If you use ZFS,
  you should use option `--zfs` to export ZFS streams, which will be much faster.

    `--[no-]consistent`
      Enable/disable consistent export. When consistently exporting a running
      container, the container is stopped, so that applications can gracefully
      exit and save their state to disk. Once the export is finished,
      the container is restarted.

    `--compression` *auto* | *off* | *gzip*
      Enable/disable compression of the dumped container data. The default is
      *auto*, which uses compresses data if they are stored uncompressed, but
      does not compress them twice. *gzip* enforces compression and *off*
      disables it.
      
      For ZFS, *auto* means using compressed stream, if the dataset has ZFS
      compression enabled and `--zfs-compressed-send` is set. If the compression
      is not enabled on the dataset or `--zfs-compressed-send` is not set, the
      stream will be compressed using *gzip*. *off* disables compression, the
      data is dumped as-is. *gzip* enforces compression, even if ZFS compression
      is enabled and `--zfs-compressed-send` is set.

  See `Common options for OpenVZ Legacy` for more command options.

`vz6 migrate stage` [*options*] *id* *destination*
  Stage migration of container *id* to *destination*. *destination* is a host
  name or an IP address of the target vpsAdminOS node. The container's config
  files are copied over SSH to *destination*.

    `-p`, `--port` *port*
      SSH port, defaults to `22`.
  
  See `Common options for OpenVZ Legacy` for more command options.

`vz6 migrate sync` *id*
  Continue staged migration of container *id* to previously configured
  *destination*. The container's rootfs is copied over to the *destination*.
  The container can still be running on the source node at this point.

`vz6 migrate transfer` *id*
  This command stops the container if it is running and makes another rootfs
  synchronization with the *destination*. The container is then started
  on the *destination* node.

`vz6 migrate cleanup` [*options*] *id*
  Perform a cleanup after migration of container *id*. The migration state is
  reset. The container by default remains on the source node in a stopped state.

    `-d`, `--[no-]delete`
      Delete the container from the source node. The container is not deleted
      by default.

`vz6 migrate cancel` [*options*] *id*
  Cancel a migration of container *id*. The migration's state is deleted from
  the source node, and all trace of the container is deleted from the
  *destination* node. This command has to be called in-between migration steps
  up until `vz6 migrate transfer`.

    `-f`, `--force`
      Cancel the migration's state on the local node, even if the remote node
      refuses to cancel. This is helpful when the migration state between the
      two nodes gets out of sync. The remote node may remain in an unconsistent
      state, but from there, the container can be deleted using `osctl ct del`
      if needed.

`vz6 migrate now` [*options*] *id* *destination*
  Perform a full container migration in a single step. This is equal to running
  `vz6 migrate stage`, `vz6 migrate sync`, `vz6 migrate transfer` and
  `vz6 migrate cleanup` in succession.

    `-p`, `--port` *port*
      SSH port, defaults to `22`.

    `-d`, `--[no-]delete`
      Delete the container from the source node. The default is to delete the
      container.

    `-y`, `--[no-]proceed`
      By default, `vz6 migrate now` asks the user if he wishes to continue after
      successful `vz6 migrate stage`. The user can review if the config file was
      converted adequately and decide to continue or cancel the migration.

  See `Common options for OpenVZ Legacy` for more command options.

### Common options for OpenVZ Legacy
`--zfs`
  Enable when the container's private area is stored on a ZFS dataset.
  `vpsadminos-convert` will export the container's data as ZFS streams.

`--zfs-dataset` *dataset*
  Specify ZFS dataset in which the container's private area is stored.

`--zfs-subdir` *directory*
  Directory in *dataset* containing the container's root filesystem, if it
  isn't directly in the dataset's root. For example, vpsAdmin stores the
  container's root filesystem in subdirectory `private/`, so that the
  container does not have access to the special `.zfs` directory located
  at the dataset root.

`--zfs-compressed-send`
  Export the ZFS streams as compressed, i.e. using `zfs send -c`. This
  feature is available since ZFS on Linux 0.7. Compressed send is disabled
  by default.

`--netif-type` `bridge`|`routed`
  vpsAdminOS supports two veth interfaces types: `bridge` and `routed`.
  Container's IP addresses are assigned to a network interface of the
  selected type. See vpsAdminOS documentation for more information about
  network configuration.

`--netif-name` *name*
  Name of the network interface within the container. Defaults to `eth0`.

`--netif-hwaddr` *addr*
  MAC address for the network interface. By default, the address is generated
  dynamically when the container is being started.

`--bridge-link` *interface*
  What bridge should the network interface be linked with. This option
  applies only when `--netif-type bridge` is set. By default, vpsAdminOS
  has bridge named `lxcbr0`, so the converter uses it.

`--vpsadmin`
  Assume the container is being managed by vpsAdmin, this implies the
  following options:

  `--zfs`
  `--zfs-dataset vz/private/%{veid}`
  `--zfs-subdir private`
  `--netif-type routed`
  `--netif-name eth0`

### Example export/import of simfs/ploop
To export container `101` from the OpenVZ node into `ct-101.tar`:

```
openvz-node $ vpsadminos-convert vz6 export 101 ct-101.tar
```

To import the exported archive on vpsAdminOS:

```
vpsadminos-node $ osctl ct import ct-101.tar
```

### Example export from ZFS

```
openvz-node $ vpsadminos-convert vz6 export \
                                            --zfs \
                                            --zfs-dataset vz/private/101 \
                                            --zfs-subdir private \
                                            101 ct-101.tar
```

The container's rootfs is expected to be in
`<mountpoint of zfs-dataset>/<zfs-subdir>`, i.e. by default
`/vz/private/101/private`. No other `zfs-subdir` than `private` is supported
at the moment.

### Example migration
You have to have vpsAdminOS node prepared and running. On the OpenVZ node,
generate a public/private key pair for `root`, if you don't already have one:

```
openvz-node $ ssh-keygen
openvz-node $ cat ~/.ssh/id_rsa.pub
```

Authorize the key to migrate containers to the vpsAdminOS node:

```
vpsadminos-node $ osctl migration authorized-keys add
<here you enter the public key>
```

Now you can continue with migration from either `simfs`/`ploop` or `ZFS`.

#### Migration from simfs/ploop
Migration from `simfs`/`ploop` cannot be completely realized through the migration
protocol, because it works only with ZFS streams. Instead, migration from
`simfs`/`ploop` uses `rsync` to copy data to the destination node. `rsync` needs
to connect to the destination vpsAdminOS node as a root, so you have to authorize
your key to login as root by adding the public key to
`/etc/ssh/authorized_keys.d/root` on the vpsAdminOS node.

When you have SSH configured, you can initiate the migration from the OpenVZ
node:

```
openvz-node $ vpsadminos-convert vz6 migrate now 101 vpsadminos-node
```

Where `vpsadminos-node` is a resolvable hostname or an IP address of the target
node.

#### Migration using ZFS
Initiate the migration from the OpenVZ node:

```
openvz-node $ vpsadminos-convert vz6 migrate now \
                                             --zfs \
                                             --zfs-dataset vz/private/101 \
                                             --zfs-subdir private \
                                             101 vpsadminos-node
```

If you forget to use `--zfs`, `rsync` will be used to migrate the container even
if it is stored in a ZFS dataset.

## BUGS
Report bugs to https://github.com/vpsfreecz/vpsadminos/issues.

## ABOUT
`vpsadminos-convert` is a part of [vpsAdminOS](https://github.com/vpsfreecz/vpsadminos).
