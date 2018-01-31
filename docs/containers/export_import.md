# Export/Import
A container can be exported into a single tar archive and later imported
on the same or a different host. The tar archive contains all needed data,
such as user/group/container configuration and rootfs.

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

By default, the ZFS stream is either dumped compressed by ZFS or is compressed
by *osctld* using *gzip*. One can choose to disable or enforce compression
using option `--compression auto | off | gzip`.

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

## Archive format
The export/import archive must contain the following files:

    .
    ├── metadata.yml
    ├── config/
    │   ├── user.yml
    │   ├── group.yml
    │   └── container.yml
    ├── rootfs/
    │   ├── base.dat[.gz]
    │   └── [incremental.dat[.gz]]
    └── snapshots.yml

`metadata.yml` describes the archive, see [below](#metadatayml).

`config/` contains *osctld* config files for the container and its user and group,
the same files you can find in `$pool/conf`.

`rootfs/` contains rootfs in the form of ZFS data streams. `base.dat` is a full
stream. If the export was consistent, `incremental.dat` contains an incremental
stream from `base.dat`.

The archive is intentionally uncompressed, as the text files are neglidible
next to the rootfs. Actually, it wouldn't be possible to create a compressed tar
from ZFS stream on the fly, because we don't know the stream's size beforehand.
The ZFS streams can be dumped in a raw form, or they can be compressed using
*gzip*, in that case `.gz` suffix is appended.

`snapshots.yml` is a list of ZFS snapshots that have been taken to generate
`rootfs/{base,incremental}.dat`. This is a convenience for when the archive
is being imported, so that *osctld* can remove the snapshots after they have
been received.

### metadata.yml
`metadata.yml` is a hash with the following data:

```yaml
---
type: full
user: <user name>
group: <group name>
container: <container id>
exported_at: <timestamp>
```
