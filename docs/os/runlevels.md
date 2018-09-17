# Runlevels
vpsAdminOS supports runlevels as suggested by
[runit documentation](http://smarden.org/runit/runlevels.html). There are
two runlevels built-in: *single* and *default*. *single* starts only gettys,
which is useful for maintenance. Runlevel *default* starts all services that
handle network configuration, importing of storage pools and starting
containers.

Every runit service belongs to one or more runlevels, you can create your own
runlevels by assigning services into it, see options under `runit.services`.

The default runlevel can be configured using option `runit.defaultRunlevel`.

## Switching runlevels
At runtime, runlevels can be switched using `svctl` or `runsvchdir`. `svctl`
is a utility from vpsAdminOS and `runsvchdir` comes with runit. The following
commands are equivalent:

```bash
svctl switch single
runsvchdir single

svctl switch default
runsvchdir default
```

It may take several seconds for runit to notice the change and start appropriate
services.

## Booting into a different runlevel
The default runlevel to boot can be changed using kernel arguments. You can
change these arguments in the bootloader if you have one, or generate config
for netboot. The recognized kernel argument is `runlevel=<name>`, e.g.
`runlevel=single`. `runlevel=single` can also be written as `1`.

## Enabling/disabling services
To make a persistent change, it should be done in your Nix configuration. If
you'd like to make temporary changes on a running system, read on.

Generally, a service is enabled by creating a symlink in the runlevel directory,
which points to the service. To disable a service, the symlink is simply removed.
runit monitors the current runlevel's directory, starts new services and stops
removed services. Runlevel directories are in `/etc/runit/runsvdir` and the
enabled services are linked from `/etc/runit/services`. For example, to enable
service `sshd` in the current runlevel, you'd do:

```bash
ln -s /etc/runit/services/sshd /etc/runit/runsvdir/current/sshd
```

You could either create and remove these symlinks manually, or you can use
`svctl`. `svctl` is a tool made for easier service and runlevel management.
You can forget where the services are stored and where the runlevels are.
`svctl` can list all or enabled services, enable/disable services in selected
runlevels and switch the current runlevel.

When called without any arguments, `svctl` lists all available services and the
runlevels they're in:

```bash
svctl
chronyd                             default   
crond                               default   
dhcpd                               default   
eudev                               default   
eudev-trigger                       default   
getty-tty1              single      default   
getty-tty2              single      default   
getty-tty3              single      default   
getty-tty4              single      default   
getty-ttyS0             single      default   
getty-ttyS1             single      default   
groups-tank                         default   
lxcfs                               default   
networking                          default   
nix                                 default   
osctld                              default   
rpcbind                             default   
rsyslog                             default   
sshd                                default   
statd                               default   
```

To enable service `sshd` in runlevel `single`, you'd do:

```bash
svctl enable sshd single
```

Review the change by listing services in runlevel `single`:

```bash
svctl list-services single
sshd
getty-tty1
getty-tty2
getty-tty3
getty-tty4
getty-ttyS0
getty-ttyS1
```

If you do not provide the runlevel's name, it defaults to the currently active
runlevel. So when you've booted in a single user mode, i.e. runlevel `single`,
`sshd` can be enabled just by:

```bash
svctl enable sshd
```
