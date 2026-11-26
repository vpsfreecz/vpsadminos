# Export/Import
A container can be exported into a single tar archive and later imported
on the same or a different host. The tar archive contains all needed data,
such as user/group/container configuration and rootfs, see
[container image specification](../specifications/container-image.md) for more
information about its contents.

## Exporting
Exporting does not actually remove the container from the node, it merely
dumps its configuration and rootfs into a file. If the container is running,
you have the option to choose either corsistent or inconsistent export.

Consistent export stops the container, if it is running, so that applications
can gracefully exit and save state to disk. Rootfs is stored as a ZFS stream,
where the first snapshot is made when the container is running. When that
snapshot is dumped, the container is stopped and the second snapshot is made.
It is dumped as an incremental stream from the first snapshot. The container is
restarted when exporting is finished.

Inconsistent export does not stop the container, it dumps the rootfs from
the running system using only one snapshot, which essentially equals to system
reset/power loss on import.

```bash
osctl ct export [--consistent] myct01 myct01-export.tar
```

*osctld* uses compressed ZFS sends by default. The receiving ZFS version and
pool must support the compression algorithms used by the source dataset.
The host setting [`osctld.settings.zfs.send.compressed`](send-receive.md#zfs-stream-compression)
controls this behavior.

The export option `--compression auto | off | gzip` controls an additional
gzip layer around the ZFS stream. With the default `auto`, *osctld* uses gzip
when compressed sends are disabled or the dataset's compression property is
`off`; otherwise, it stores the stream without gzip. `gzip` always adds gzip,
and `off` disables that layer. These options do not disable compressed ZFS
sends.

## Importing
To import a previously exported container, use:

```bash
osctl ct import myct01-export.tar
```

It is possible to override the container id, or the name of its user and group.
This allows you to import one archive multiple times, essentially cloning
the containers.

```bash
osctl ct import --as-id bettername myct01-export.tar
```

Similarily, one can use `--as-user` or `--as-group` to import the container with
a different user or group. Note that both the user and the group have to already
exist, if you're using these options. The existing user/group is used instead of
the ones in the exported archive.
