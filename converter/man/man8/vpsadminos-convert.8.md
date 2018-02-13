# vpsadminos-convert 8            2018-02-06                              0.1.0

## NAME
`vpsadminos-convert` - convert existing containers into vpsAdminOS.

## SYNOPSIS
`vpsadminos-convert` *command* [*command options*] [*arguments...*]

## DESCRIPTION
`vpsadminos-convert` is a tool for converting existing containers into
vpsAdminOS containers. Currently supported is only OpenVZ Legacy with ZFS,
as used by [vpsAdmin](https://github.com/vpsfreecz/vpsadmin).

## OPENVZ LEGACY COMMANDS
At the moment, `vpsadminos-convert` can be used to export OpenVZ container into
a tar archive. The archive is then copied to vpsAdminOS node by the user and
then imported using `osctl ct import` *file*, see osctl(8).

`vz6 export` [*options*] *ctid* *file*
  Export OpenVZ container *ctid* into a tar archive saved to *file*.

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

    `--route-via` *network*
      Interconnecting network via which the container's IP addresses are routed.
      Applies only when `--netif-type routed` is set. Can be used once for IPv4
      and once for IPv6. This option has to be specified for all IP versions
      that the container is using.

    `--vpsadmin`
      Assume the container is being managed by vpsAdmin, this implies the
      following options:

      `--zfs`
      `--zfs-dataset vz/private/%{veid}`
      `--zfs-subdir private`
      `--netif-type routed`
      `--netif-name eth0`

      `--route-via` has to be provided.

### Example usage
To export container `101` from the OpenVZ node into `ct-101.tar`:

    openvz-node $ vpsadminos-convert vz6 export --vpsadmin 101 ct-101.tar

To import the exported archive on vpsAdminOS:

    vpsadminos-node $ osctl ct import ct-101.tar

## BUGS
Report bugs to https://github.com/vpsfreecz/vpsadminos/issues.

## ABOUT
`vpsadminos-convert` is a part of [vpsAdminOS](https://github.com/vpsfreecz/vpsadminos).
