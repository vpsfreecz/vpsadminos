# Container image
Container image is generally used to export/import containers from/to
vpsAdminOS nodes.

# Structure
The image archive must contain the following files:

    .
    ├── metadata.yml
    ├── config/
    │   ├── user.yml
    │   ├── group.yml
    │   └── container.yml
    ├── rootfs/
    │   ├── base.dat[.gz] | base.tar.gz
    │   ├── [incremental.dat[.gz]]
    │   └── [subdataset]
    │       ├── base.dat[.gz]
    │       └── [incremental.dat[.gz]]
    ├── [hooks/]
    │   └── <hook>
    └── snapshots.yml

`metadata.yml` describes the archive, see [below](#metadatayml).

`config/` contains *osctld* config files for the container and its user and group,
the same files you can find in `$pool/conf`.

`rootfs/` contains rootfs in the form of ZFS data streams or as a tar archive,
depending on `format` in `metadata.yml`.

For ZFS, `base.dat` is a full stream. If the export was consistent,
`incremental.dat` contains an incremental stream from `base.dat`. Subdatasets
are exported to subdirectories with the dataset's relative name.

When the rootfs is exported as a tar archive in `base.tar.gz`, there can be no
subdatasets, everything is in that one archive. This is used when exporting
containers from other virtualization technologies into vpsAdminOS.

The archive is intentionally uncompressed, as the text files are neglidible
next to the rootfs. Actually, it wouldn't be possible to create a compressed tar
from ZFS stream on the fly, because we don't know the stream's size beforehand.
The ZFS streams can be dumped in a raw form, or they can be compressed using
*gzip*, in that case `.gz` suffix is appended.

Directory `hooks` can contain user-defined script hooks that are run by *osctld*
when the container is started or stopped. This directory is optional. See
[man osctl(8)](https://man.vpsadminos.org/osctl/man8/osctl.8.html#script-hooks)
for a list of supported script hooks.

`snapshots.yml` is a list of ZFS snapshots that have been taken to generate
ZFS streams stored at `rootfs/`. This is a convenience for when the archive
is being imported, so that *osctld* can remove the snapshots after they have
been received.

# metadata.yml
`metadata.yml` is a hash with the following data:

```yaml
---
type: full | skel
format: zfs | tar
user: <user name>
group: <group name>
container: <container id>
datasets: <list of container subdatasets>
exported_at: <timestamp>
```
