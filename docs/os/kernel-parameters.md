# Kernel parameters
Kernel parameters can be used to change runtime behaviour of vpsAdminOS. They
can be set e.g. from grub command line or configured with option
`boot.kernelParams`. Only vpsAdminOS-specific parameters are documented here.

## osctl.pools
Can be used to prevent ZFS pools from being imported into *osctld*.

Note that this parameter will have a lasting effect until the system is rebooted
without it. *osctld* will **never** automatically import pools, even after
the service is restarted.

Usage:

- `osctl.pools=0`

## osctl.autostart
Can be used to disable container auto-start mechanism in *osctld*. ZFS pools
can be imported, but no containers will be started automatically.

Note that this parameter will have a lasting effect until the system is rebooted
without it. *osctld* will **never** automatically start containers, even after
the service is restarted.

Usage:

- `osctl.autostart=0`

## runlevel, 1
Can be used to change initial runlevel.

Usage:

- `runlevel=single` to start only gettys
- `runlevel=rescue` to bring up only single with network and sshd
- `1` is alias for `runlevel=single`
- `runlevel=default` to boot the system-configured default runlevel

See [runlevels](runlevels.md) for more information.

## zfs\_force
If booting from ZFS root, this parameter will import the root zpool forcefully,
i.e. with `zpool import -f`.

Usage:

- `zfs_force`
- `zfs_force=1`
