# Configuration

vpsAdminOS uses Nix configuration language. It reuses a number of NixOS modules
for system configuration and also adds some of its own. Explore `os/modules/`
to see its capabilities.

Default and example configs are included in `os/configs/` directory.

  * `make qemu` uses `qemu.nix`
  * `make iso-image` uses `iso.nix`

The simplest way to start with vpsAdminOS is to clone its repository and
put your configuration in `os/configs/local.nix`, which you can base on
`os/configs/local.nix.sample`. `local.nix` is imported with `make qemu` automatically
if it exists.

Another option is to put path to your config to environment variable
`VPSADMINOS_CONFIG`, e.g.:

```
export VPSADMINOS_CONFIG=/where/is/your/config.nix
make qemu
```

## Kernel runtime parameters (sysctl)

Declare kernel runtime settings with `boot.kernel.sysctl`:

```nix
boot.kernel.sysctl = {
  "vm.swappiness" = 60;
};
```

The settings are written to `/etc/sysctl.d/60-nixos.conf`. Boot stage 1 applies
sysctl files after loading kernel modules and before setting up networking.
The `sysctl` runit service applies them again when the default or rescue
runlevel starts. This second application is intentional. Single and custom
runlevels do not include this service automatically.

On a live configuration `switch` or `test`, the service runs when managed
sysctl files change. Its inputs include enabled `environment.etc` entries whose
effective target is `sysctl.conf` or a direct `sysctl.d/*.conf` file, including
the generated `60-nixos.conf`. Content changes, additions, removals and target
renames trigger an application. An otherwise unchanged configuration switch
does not rerun the service, so a manual runtime override remains in place.
Editing an unmanaged file alone does not trigger the service.

The service uses procps `sysctl -w --system`. Directory priority is
`/etc/sysctl.d`, `/run/sysctl.d`, `/usr/local/lib/sysctl.d`, `/usr/lib/sysctl.d`,
then `/lib/sysctl.d`. A file with the same name in a higher-priority directory
replaces the lower-priority copy. Files are applied in filename order, and
`/etc/sysctl.conf` is read last. The command reads the full system configuration,
including unmanaged files, whenever the service runs. Settings applied later
can override earlier ones.

Each start makes one application attempt. A failure can leave some values
changed; the service does not roll them back or retry automatically. Diagnostics
are in `/var/log/sysctl/current`. Successful application publishes
`/run/service/sysctl/applied` for the current managed inputs, which the custom
completion check validates:

```bash
/service/sysctl/check
sysctl -n vm.swappiness
```

A successful `switch` exit does not prove sysctl application succeeded. The
switcher retains its existing service-error handling, and a newly introduced
service starts asynchronously. `sv status` and `sv check` alone are also
insufficient: a completed one-shot service is normally down, and `sv check`
can skip its custom check in that state. Use the direct completion check after
observing the attempt finish, inspect its logs, and read back relevant values.
The success stamp records an application, not continuous equality with runtime
settings.

### Retrying an application

First stop the service and invalidate earlier completion markers:

```bash
sv stop sysctl
rm -f /run/service/sysctl/applied /run/service/sysctl/done
tail -n 0 -F /var/log/sysctl/current
```

Confirm that `sv stop` succeeded before proceeding. Leave the log follower
running, then start one attempt from another terminal:

```bash
sv once sysctl
```

Observe fresh application output and its success or failure diagnostic. After
that attempt finishes, stop following the log and check:

```bash
sv status sysctl
/service/sysctl/check
sysctl -n vm.swappiness
```

An initial down state immediately after `sv once` can precede execution; it
does not establish completion. Do not reuse an old success marker or infer
latest-attempt success from the start command returning. A failed completed
attempt leaves no valid application stamp. Correct the reported configuration
error before retrying. A retry reads current unmanaged files too.

Whenever the service runs, it reapplies configured values and can overwrite
manual runtime changes. Setting a declaration to `null` or removing a key/file
does not reset its live value. Removing the service or rolling back to an OS
without it does not apply old values automatically. Check and explicitly
restore required values during a rollback, or boot an appropriate configuration.
The `boot` action alone only prepares boot configuration; `dry-activate` reports
planned service actions without applying sysctls.

## Declarative containers

It is possible to built the `os` with images for containers to be imported and
started on boot by `osctld`. For examples see `configs/containers` directory.
This functionality is experimental and mostly used for testing.

## Explicit configuration and dependencies

Most of the `make` targets are wrappers for `nix build` using the repository
flake. The following example demonstrates how to build the `os` directly
without `make`.

```bash
cd os
nix build --out-link result/qemu ..#qemu
```

To use a custom configuration, set `VPSADMINOS_CONFIG` to an absolute path and
build with `--impure`, e.g.:

```bash
cd os
VPSADMINOS_CONFIG=/where/is/your/config.nix nix build --impure --out-link result/qemu ..#qemu
```
