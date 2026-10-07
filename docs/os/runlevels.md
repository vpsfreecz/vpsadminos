# Runlevels
vpsAdminOS supports runlevels as suggested by
[runit documentation](http://smarden.org/runit/runlevels.html). There are
three runlevels built-in: *single*, *rescue* and *default*. *single* starts only
gettys, which is useful for maintenance. Runlevel *rescue* starts gettys,
configures network and starts sshd. *rescue* does not import ZFS pools and does
not start *osctld*. Runlevel *default* starts all services that
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
channel-registration                            default   
chronyd                                         default   
cpufreq                                         default   
crond                                           default   
dhcpd                                           default   
eudev                               rescue      default   
eudev-trigger                       rescue      default   
getty-tty1              single      rescue      default   
getty-tty2              single      rescue      default   
getty-tty3              single      rescue      default   
getty-tty4              single      rescue      default   
getty-ttyS0             single      rescue      default   
getty-ttyS1             single      rescue      default   
haveged                                         default   
histfile-tank                                   default   
networking                          rescue      default   
nfsd                                            default   
nix                                 rescue      default   
opensmtpd                                       default   
osctld                                          default   
pool-tank                                       default   
rpcbind                                         default   
rsyslog                             rescue      default   
sshd                                rescue      default   
statd                                           default   
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

## Service cgroup entry

Each generated service `run` script creates its cgroup and writes its own PID
to `cgroup.procs` before sourcing helpers, setting PATH and environment, or
running the configured body. If creation fails, the script prints
`runit: cgroup creation failed` to stderr and exits with status 1. If the PID
write fails, including failure to open the destination, it prints
`runit: cgroup attachment failed` to stderr and exits with status 1. Both
failures stop before the run body and its one-shot success marker. Successful
entry preserves the body's shell behavior.

This entry assumes the hierarchy prepared by stage 1: the named systemd
hierarchy at `/sys/fs/cgroup/systemd/runit` for v1, or
`/sys/fs/cgroup/system/service` for v2, linked through
`/run/runit/cgroup.service`. Successful commands on a substituted ordinary
filesystem do not prove kernel membership. Entry supplies no service
incarnation, recursive descendant coverage, wait acknowledgement or storage
exclusion proof.

The refusal affects only `run`. Check, control, finish and log scripts keep
their existing behavior. Runit may invoke a finish handler after failed entry
and retry the service. Interrupted entry can leave a directory; the script does
not remove it or signal its existing members. Use ordinary service diagnostics
to inspect a failure.

The generated run paths participate in ordinary configuration activation and
can cause service restarts under the existing change and protection rules.
No coordinated fleet update or on-disk migration is required, but older
generations retain their entry behavior. Rolling back restores that behavior
and may restart services; it does not release another component's maintenance
ownership. Entry refusal does not account for earlier starts, escaped children,
independent producers or exceptional physical effects.

## Building without automatic osctld startup

`osctld.enable` defaults to `true`. Set it to `false` to omit osctld from all
runlevels while retaining its service definition, generated configuration and
ordinary tools, including `osctl`, `osup` and `svctl`:

```nix
{
  osctld.enable = false;
  osctl.pools = { };
  osctl.exportfs.enable = false;
  boot.zfs.pools.tank.install = false;
}
```

Every configured ZFS pool must have `install = false`. Configuration evaluation
fails if `osctl.pools` is nonempty, `osctl.exportfs` is enabled, pool installation
is enabled or osctld is forced into a runlevel. These checks prevent the
configured consumers from waiting for a daemon that will not start.

The ZFS pool service still imports pools, mounts datasets and applies configured
properties. With osctld disabled, it skips the osctl active-property lookup,
daemon wait, pool installation/import and parallel-start/stop settings. It
preserves retained osctl state and `org.vpsadminos.osctl:active`. Existing ZFS
startup configuration can write to storage; this option does not make ZFS
read-only.

Configuration activation skips `osctl activate` when osctld is absent from the
destination runlevel. Activation keeps its existing restart handling when
osctld is selected. A successful activation does not prove that a removed
service and all its children have stopped. Neither an absent socket nor a
successful activation exit proves that storage writers are excluded.

The installed `halt`, `poweroff` and `reboot` commands use the generation's
`osctld.enable` value. When it is `false`, they skip container listing and
osctl shutdown/abort. Runit's final shutdown stage also skips its osctl shutdown
command and retains both hardware-clock writes. Commands without `--force`
still collect a reason, confirm the hostname and count down. Logging, halt hooks,
kexec handling and final runit dispatch are unchanged. The commands record the
reason in syslog without sending container wall messages.

Use the selected generation's ordinary commands. If you invoke an older store
script directly, it uses that generation's shutdown policy. This option does not
stop a manually started daemon or constrain arbitrary halt hooks; it does not
prove that storage writers are excluded.

Use the ordinary generation selection described in [Updates](updates.md).
`switch` selects the boot configuration and activates it; `boot` selects it
without runtime activation. `test` changes the running configuration only.
Transient `svctl` changes do not establish the generation used on the next boot.
A fresh boot into the disabled generation continues to omit automatic osctld
startup, but invalidates evidence tied to the previous boot or process identity.

This option changes no on-disk format and requires no coordinated fleet update.
Older sources that lack the option refuse its declaration. Booting an older
ordinary generation can restart storage writers; it is not a safe rollback
while another component owns storage maintenance. The option does not provide
that ownership, authorize storage actions or exclude other producers.
