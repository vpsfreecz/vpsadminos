# Setup

When vpsAdminOS has booted, all that has to be done is to create a zpool and
give it to *osctld*, for example:

```
zpool create tank <disks...>
```

For testing purposes, you might want to create a zpool from file:

```
dd if=/dev/zero of=/tank.zpool bs=1M count=4096
zpool create tank /tank.zpool
```

When the zpool is ready, let *osctld* use it:

```
osctl pool install tank
```

`osctl pool install` will mark the pool so that *osctld* will always import it
on start. It works by settings a custom user property called
`org.vpsadminos.osctl:active` to `yes`. All configuration and data is stored on
installed zpools, the rest of the system does not have to be persistent between
reboots. `osctl pool install` will also automatically import the pool into *osctld*.

*osctld* will create several datasets and will generally assume that no one else
is using the zpool. If you'd like, it is possible to scope *osctld* to
a subdataset on your zpool, so that it will ignore all datasets above its own.
The following command will scope *osctld* to dataset `tank/data/osctld`:

```bash
zfs create -p tank/data/osctld
osctl pool install --dataset tank/data/osctld tank
```

When you have at least one zpool imported and installed, you can proceed
to [user](users.md) and [container](containers.md) management.
