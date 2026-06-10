# Kernel and ZFS development

vpsAdminOS normally builds Linux and OpenZFS through Nix from pinned source
revisions. That remains the release path: final integration still updates
`os/packages/linux/available-kernels.nix`, refreshes source hashes, builds with
Nix and passes the normal QEMU/test-runner gates.

For kernel and ZFS development, it is often faster to keep local Kbuild and ZFS
build directories hot, stage the resulting artifacts, and let the vpsAdminOS
Nix evaluation copy those staged artifacts into QEMU or test-runner systems. The
compile work happens outside the Nix sandbox; Nix still assembles the bootable
system and records the staged files in the closure.

## Kernel stage

Build and stage a local kernel with:

```bash
VPSADMINOS_KERNEL_SRC=/path/to/linux \
make kernel-dev-build
```

By default, the kernel stage uses `os/configs/kernel-dev-qemu.nix`. That
module imports the normal QEMU configuration and forces ZFS to be built as an
external module. Set `VPSADMINOS_KERNEL_CONFIG_MODULE` to a focused
configuration, such as `os/configs/proxy-exec-qemu.nix`, when the development
loop needs extra kernel options.

The default state directory is
`$XDG_STATE_HOME/vpsadminos/kernel-dev/<repo-name>` or
`$HOME/.local/state/vpsadminos/kernel-dev/<repo-name>`. Override it with
`VPSADMINOS_KERNEL_DEV_ROOT` when maintaining multiple independent kernel
lines.

After a successful build, export the stage for Nix:

```bash
eval "$(make kernel-dev-env)"
```

The staged kernel layout is:

- `stage/out`: `bzImage`, `System.map` and installed in-tree modules;
- `stage/dev-input`: source, config, `vmlinux` and `Module.symvers` for
  external module builds;
- `stage/applied-kernel-patches.tsv`: patches from the evaluated vpsAdminOS
  kernel package that were applied, or found already present, in the prepared
  source;
- `stage/meta.env` and `stage/meta.nix`: version, module directory and source
  metadata.

By default the builder applies the same `kernelPatches` advertised by the
evaluated vpsAdminOS kernel package before compiling the prepared source. This
keeps local staged kernels aligned with the normal Nix-packaged kernel, for
example the vpsAdminOS bridge STP helper path patch. Set
`VPSADMINOS_KERNEL_DEV_APPLY_PACKAGE_PATCHES=0` only when deliberately testing
the raw Linux tree without package patches.

`VPSADMINOS_KERNEL_DEV_MODULES=skip` reuses the previously staged module tree
and omits the Kbuild `modules` target. `VPSADMINOS_KERNEL_DEV_DEV=skip` reuses
the previous external-module input. These modes are only for deliberate tight
loops where modules, exported symbols and external-module inputs are known
unchanged. Reuse is refused when the evaluated package patch list, kernel
config, `Module.symvers`, or `vmlinux` changed, because those conditions can
make the staged `bzImage` reject the reused module tree. A developer can set
`VPSADMINOS_KERNEL_DEV_ALLOW_CHANGED_VMLINUX_REUSE=1` to force reuse after a
changed `vmlinux`, but that is an explicit stale-module risk and must not be
used for validation gates. The safe default refreshes both.

Even with `VPSADMINOS_KERNEL_DEV_MODULES=always`, Kbuild can leave unchanged
module `.ko` files in place after a built-in kernel change produces a new
`vmlinux`. The dev builder detects this by comparing the new `vmlinux` with the
previous staged `dev-input/vmlinux`; when it changed, the builder removes only
module link/modpost artifacts (`*.ko`, `*.mod*`, `.tmp_versions`) and reruns
`make modules`. This is intentionally cheaper than `make clean`, but it forces
fresh module version/signature data so stage-1 boot does not pair a new
`bzImage` with stale modules.

## ZFS stage

Build OpenZFS against the staged kernel:

```bash
eval "$(make kernel-dev-env)"
VPSADMINOS_ZFS_SRC=/path/to/zfs make zfs-dev-build
eval "$(make zfs-dev-env)"
```

The default ZFS state directory is
`$XDG_STATE_HOME/vpsadminos/zfs-dev/<repo-name>` or
`$HOME/.local/state/vpsadminos/zfs-dev/<repo-name>`. The staged kernel module
package must contain at least `spl.ko.xz` and `zfs.ko.xz` under
`stage/kernel/out/lib/modules/<kernel-release>/extra/`. It intentionally does
not own `modules.*` depmod index files; those are generated for the combined
kernel module tree after kernel, ZFS and test helper modules are assembled.

By default only kernel modules are built. Set `VPSADMINOS_ZFS_DEV_USER=always`
when userspace changes also have to be staged. `VPSADMINOS_ZFS_DEV_KERNEL=skip`
reuses the previous staged ZFS kernel modules only when the kernel-stage
fingerprint is unchanged; otherwise it fails and asks for a ZFS module rebuild.

## Using stages

Development configs can consume the staged artifacts through:

```bash
export VPSADMINOS_LOCAL_KERNEL_STAGE=/path/to/kernel/stage
export VPSADMINOS_LOCAL_ZFS_STAGE=/path/to/zfs/stage
```

`os/configs/local-dev-qemu.nix` is the reusable staged-artifact hook. It is
imported by `os/configs/kernel-dev-qemu.nix` for general QEMU development and
by `os/configs/proxy-exec-qemu.nix` for the proxy-execution validation loop.
Run Nix builds that depend on these variables with impure evaluation, for
example through the test runner or a config-specific QEMU target that passes
`--impure`.

Focused single-test evaluation uses the checkout's flake nixpkgs input when no
repo-local `nixpkgs` path exists, so local-stage tests do not depend on the
operator shell's ambient `<nixpkgs>` channel. A proxy-execution bad-neighbor
JSON can be built from staged artifacts with:

```bash
export VPSADMINOS_LOCAL_KERNEL_STAGE=/path/to/kernel/stage
export VPSADMINOS_LOCAL_ZFS_STAGE=/path/to/zfs/stage
export VPSADMINOS_ENABLE_SCHED_PROXY_EXEC_LOCK_BADNEIGHBOR_TEST=1
export VPSADMINOS_ONLY_SCHED_PROXY_EXEC_LOCK_BADNEIGHBOR_TEST=1
nix-build test-runner/nix/evaluate-tests.nix \
  --arg repoRoot "$PWD" \
  --argstr system x86_64-linux \
  --argstr mode testJson \
  --argstr testPath kernel/sched-proxy-exec-lock-badneighbor
```

This fast path is not a substitute for release validation. Before publishing a
6.18 branch, rebuild from the pinned Linux/ZFS revisions and run the required
project harness gates on the exact commits intended for integration.

## Offloaded focused tests

Timing-sensitive development runs can be offloaded to a remote vpsAdminOS host
with KVM. The offload path still uses the project test-runner; it builds the
focused test JSON locally, copies the JSON and packaged test-runner closure to
the remote host, starts N transient systemd lanes there, and collects result
rows from the test-runner logs.

Configure the remote host explicitly:

```bash
export VPSADMINOS_TEST_OFFLOAD_HOST=root@host.example
export VPSADMINOS_TEST_OFFLOAD_KNOWN_HOSTS=/path/to/known_hosts
export VPSADMINOS_TEST_OFFLOAD_LANES=4
```

Run a focused test from already-staged artifacts:

```bash
eval "$(make kernel-dev-env)"
eval "$(make zfs-dev-env)"
make test-json-offload DEV_TEST=kernel/sched-proxy-exec-lock-badneighbor
```

The same path can be driven directly:

```bash
tools/vpsadminos-test-json-offload run kernel/sched-proxy-exec-lock-badneighbor
tools/vpsadminos-test-json-offload status kernel/sched-proxy-exec-lock-badneighbor
tools/vpsadminos-test-json-offload watch kernel/sched-proxy-exec-lock-badneighbor
tools/vpsadminos-test-json-offload collect kernel/sched-proxy-exec-lock-badneighbor
tools/vpsadminos-test-json-offload summary kernel/sched-proxy-exec-lock-badneighbor
```

`watch` is the preferred unattended mode for timing-sensitive iteration. Each
refresh uses one bounded remote snapshot for host load, CPU count, all lane
systemd states, result row counts, lane log size/age, active-since timestamps,
fatal-log detection, and the latest parsed proxy-exec row per lane. This keeps
the monitor bounded even with multiple lanes: a sick remote status path can
consume at most one poll budget per refresh, not one budget per lane and per
probe type. When all lanes stop, `watch` automatically collects artifacts and
writes the summary/classification files. `summary` can be run later against the
same state directory to recreate the compact table without touching the remote
host.

For `kernel/sched-proxy-exec-lock-badneighbor`, `watch` also defaults to a
stale-progress watchdog: if an active lane emits no new proxy-exec progress,
result, or summary row and shows no lane-log growth for `900` seconds, the
wrapper first captures bounded systemd, journal, process, file-list, and
lane-log diagnostics, then terminates only that run's recorded systemd
lane unit and continues to artifact collection. The lock-badneighbor harness
emits progress rows before and after long phases such as boot, container
setup, baseline measurement, bully warmup, contended measurement, and result
emission. These rows are only liveness markers for the watchdog and monitor
display; collection and validation still require real result or summary rows.
Fatal guest log patterns such as kernel panic, soft lockup, Oops/general
protection fault, hung task, RCU stall, failed module insertion, or missing
root device are treated as immediate stale-lane failure evidence even if the
log is still growing. Lane-log activity includes the test-runner log and
machine logs such as `machine-console.log`.
The watcher records lane launch time, durable row-progress state, and durable
log-activity state, so restarting `watch` does not give an already-stale lane a
fresh timeout window. Override this with
`VPSADMINOS_TEST_OFFLOAD_STALE_TIMEOUT` (`0` disables it),
`VPSADMINOS_TEST_OFFLOAD_STALE_STOP_GRACE`, and
`VPSADMINOS_TEST_OFFLOAD_STALE_DIAG_LINES`. Stale lane stops are recorded in
`stale-lanes.tsv`, and pre-stop diagnostic snapshots are written under
`stale-diagnostics/`, next to the normal event and classification files.
The offload controller also bounds its own SSH control operations, so a stale
lane, wedged diagnostic command, or broken transport cannot wedge `watch`
indefinitely. SSH defaults are `BatchMode=yes`, `ConnectTimeout=15`,
`ServerAliveInterval=30`, `ServerAliveCountMax=4`,
`VPSADMINOS_TEST_OFFLOAD_SSH_COMMAND_TIMEOUT=120`,
`VPSADMINOS_TEST_OFFLOAD_SSH_POLL_TIMEOUT=30`, and
`VPSADMINOS_TEST_OFFLOAD_SSH_DIAG_TIMEOUT=240`. Set a command timeout to `0`
only when deliberately debugging the offload controller itself.
Unknown lane state is not treated as finished; the controller waits for a
clear terminal state or for stale/fatal diagnostics to stop the run-owned lane.

Remote lanes inherit test-runner basics such as `TEST_TIMEOUT` and also forward
selected test knobs from the local environment. By default the offload wrapper
forwards variables with the `VPSADMINOS_PROXY_` prefix, so proxy-exec runs can
carry settings such as `VPSADMINOS_PROXY_LOCK_FULL_MATRIX` and
`VPSADMINOS_PROXY_LOCK_REQUIRE_VALIDATION` into `ostest` lanes. Extend or
replace the forwarding set with:

```bash
export VPSADMINOS_TEST_OFFLOAD_FORWARD_ENV_PREFIXES='VPSADMINOS_PROXY_'
export VPSADMINOS_TEST_OFFLOAD_FORWARD_ENV_NAMES='EXACT_ENV_NAME'
```

The `kernel/sched-proxy-exec-lock-badneighbor` test uses a saturated bully
container and an unconstrained victim container to exercise owner-bearing lock
families. `VPSADMINOS_PROXY_LOCK_PRESSURE_MODE` selects how the bully is
constrained. The default `weight` mode lowers the bully cgroup's `cpu.weight`
or cgroup-v1 `cpu.shares` and relies on normal fair scheduling competition to
starve a runnable/on-rq lock owner. The older `quota` mode still applies
`osctl ct set cpu-limit` and is useful as a diagnostic for CFS bandwidth
accounting, but Linux 6.18 task-based CFS throttling does not faithfully leave
ordinary user tasks in throttled limbo while they hold shared kernel locks.
The bully CPU workers default to sixteen times the VM CPU count, overridable
with `VPSADMINOS_PROXY_LOCK_CPU_WORKERS`, so the owner payload stays saturated
instead of accidentally giving the lock worker a whole host CPU. The bully lock
worker defaults to
`VPSADMINOS_PROXY_LOCK_HOLD_REPS=1000`, so each procfs write performs a long
bounded burst of lock holds in kernel context. This keeps the holder active
long enough for victim probes without letting the shell reacquire path dominate
the result. The holder also
defaults to `VPSADMINOS_PROXY_LOCK_HOLD_YIELD_US=5000`, which calls the
kernel's exported `yield()` while the critical section is still held after
each interval of holder scheduler runtime. In weight mode this is a
test-helper rendezvous point for normal fair preemption; in quota mode it is a
diagnostic rendezvous point for CFS bandwidth pressure. Cleanup writes a
stop sentinel for the shell loop and also writes `stop` to
`/proc/proxy_lock_badneighbor_control`, which lets the in-kernel burst break at
the next polling point instead of waiting for all hold repetitions to finish.
Useful focused knobs are
`VPSADMINOS_PROXY_LOCK_CLASS_FILTER`,
`VPSADMINOS_PROXY_LOCK_CPU_WORKERS`,
`VPSADMINOS_PROXY_LOCK_CONTENDED_COUNT`,
`VPSADMINOS_PROXY_LOCK_MEASURE_TIMEOUT`,
`VPSADMINOS_PROXY_LOCK_PRESSURE_MODE`,
`VPSADMINOS_PROXY_LOCK_CPU_WEIGHT`,
`VPSADMINOS_PROXY_LOCK_CPU_SHARES`,
`VPSADMINOS_PROXY_LOCK_HOLD_YIELD_US`,
`VPSADMINOS_PROXY_LOCK_ACTIVE_MIN_AGE_MS`,
`VPSADMINOS_PROXY_LOCK_ACTIVE_MIN_OFFCPU_MS`,
`VPSADMINOS_PROXY_LOCK_ACTIVE_WAIT_TIMEOUT_MS`, and
`VPSADMINOS_PROXY_LOCK_ACTIVE_WAIT_ERROR_LIMIT`. Warmup requires a live holder
in the bully payload cgroup and positive bully CPU usage. Quota mode also
requires movement in `nr_throttled`; `throttled_usec` is still recorded, but it
is not a mandatory predicate by default because some cgroup/kernel combinations
move throttle event counters without useful microsecond deltas. Set
`VPSADMINOS_PROXY_LOCK_WARM_THROTTLED_USEC_MIN` only for a run that explicitly
needs to require that counter. Contended victim probes wait for an active
holder and, by default, require that holder to have been active for half of
`VPSADMINOS_PROXY_LOCK_HOLD_US` before probing. This keeps disabled controls
from measuring only fresh bounded critical sections before the saturated bully
has had a chance to starve the holder. Set
`VPSADMINOS_PROXY_LOCK_ACTIVE_MIN_AGE_MS=0` only for a diagnostic run that
intentionally wants the older immediate-active sampling shape. When specifically
debugging quota-stalled lock owners, set
`VPSADMINOS_PROXY_LOCK_ACTIVE_MIN_OFFCPU_MS` so victim probes wait for a holder
that is still inside the critical section and has already accumulated live
off-CPU time. The proc helper records hold runtime from the task scheduler
runtime counter and exposes `active_runtime_us` plus live `active_offcpu_us` in
`/proc/proxy_lock_badneighbor_hold`. The off-CPU value is derived at proc read
time from live active elapsed time minus the holder's last recorded scheduler
runtime, so a preempted owner remains visible while it is off-CPU inside the
critical section. This avoids treating short wall-clock poll gaps as proof of
CPU service. If the active holder does not satisfy the age/off-CPU predicate
often enough, the helper emits a structured
`timeout=true` row with `timeout_reason=active_wait` instead of relying on the
outer test-runner timeout. Collected lock-badneighbor summaries preserve the
timeout reason, sample count, active-wait error count, CPU worker count, hold
yield interval, and holder yield count in the compact classification notes.
Reader-owned rwsem cases are split into exact single-reader and bounded
representative-reader rows because the source exposes those as distinct owner
states. Per-CPU rwsem reader validation uses one bounded representative-reader
row, driven by `VPSADMINOS_PROXY_LOCK_READER_WORKERS` workers by default,
because the source does not expose a separate exact single-reader state for
that lock family. The final lock-badneighbor summary is intentionally stricter
than raw proxy-selection counters: each enabled row must finish without
timeout, observe the lock-family-specific owner path, reproduce a materially
worse disabled control, and show owner-side punishment evidence. Weight mode
requires donated runtime plus owner cgroup CPU usage movement. Quota mode also
requires owner throttle-event movement and hierarchy-throttled donation
evidence. Raw result rows include CPU-controller snapshots from the container
parent, `user-owned`, and active holder cgroups, including `cpu.weight` or
`cpu.shares` where available, so weak controls can be distinguished from a
misplaced or ineffective pressure setting. `throttled_usec` remains a
diagnostic field in summaries and classifications.

The checked-in default is intentionally shorter and tolerant of noisy
hypervisors: it runs an enabled-side signal regression for representative
`mutex`, `rwsem_read_single`, and `percpu_rwsem_read_representative` rows,
requires proxy activity plus owner-side donated-runtime accounting, and does
not require the expensive disabled-control latency proof. This catches
regressions in proxying behavior without depending on absolute latency
thresholds or on a long disabled run finishing under transient host load.
Override the default row set with `VPSADMINOS_PROXY_LOCK_DEFAULT_CLASSES`.

For source-debugging a narrow lock family, set
`VPSADMINOS_PROXY_LOCK_CLASS_FILTER` to a comma-separated list of row names, for
example
`VPSADMINOS_PROXY_LOCK_CLASS_FILTER=percpu_rwsem_write,percpu_rwsem_read_representative`.
For release validation, opt into the complete owner-bearing matrix and the
enabled+disabled production proof:

```bash
export VPSADMINOS_PROXY_LOCK_FULL_MATRIX=1
export VPSADMINOS_PROXY_LOCK_REQUIRE_VALIDATION=1
export VPSADMINOS_PROXY_LOCK_MEASURE_TIMEOUT=7200
export VPSADMINOS_TEST_TIMEOUT=86400
export VPSADMINOS_TEST_OFFLOAD_STALE_TIMEOUT=0
```

The high-level Linux+ZFS development loop builds stages first and then offloads
the focused test:

```bash
VPSADMINOS_KERNEL_SRC=/path/to/linux \
VPSADMINOS_ZFS_SRC=/path/to/zfs \
make kernel-zfs-dev-test-watch DEV_TEST=kernel/sched-proxy-exec-lock-badneighbor
```

`tools/vpsadminos-kernel-zfs-dev-run` passes through all lower-level
environment variables. Its default is intentionally conservative: refresh the
kernel image, in-tree modules, kernel dev input, and ZFS kernel modules before
building the test JSON. For `kernel/sched-proxy-exec*` tests it uses
`os/configs/proxy-exec-qemu.nix` unless `VPSADMINOS_KERNEL_CONFIG_MODULE` is
set; other tests default to `os/configs/kernel-dev-qemu.nix`. Tight-loop skip
modes remain available, but use them only after proving the edit cannot affect
modules, exported symbols, generated headers, or external-module inputs.

The offload state is kept outside the repository under
`$XDG_STATE_HOME/vpsadminos/test-offload/` or
`$HOME/.local/state/vpsadminos/test-offload/`. Each run records:

- `manifest.env`: local/remote paths, store paths, lane count and unit prefix;
- `lanes.tsv`: remote lane number, unit name, state directory and launch epoch;
- `events.tsv`: raw parsed proxy-exec result and summary rows from remote logs;
- `lane-results.tsv`: per-lane test-result files and failure diagnostics;
- `summary.json`: compact lock-badneighbor result and summary rows;
- `classification.tsv`: compact validation/classification table derived from
  final harness summaries where available, falling back to individual result
  rows when a lane fails before summary emission;
- `stale-lanes.tsv`: rows written only when the offload watcher stops one of
  this run's own systemd lane units for stale proxy-exec progress/result/summary
  rows and stale lane-log activity;
- `stale-diagnostics/`: bounded systemd, journal, process, file-list, and
  lane-log snapshots captured before a stale lane is stopped;
- `watch-progress.tsv`: durable per-lane row count, log activity, and progress
  epochs used by restarted watchers to keep stale-lane timeout accounting
  monotonic.

For proxy-exec tests, `classification.tsv` is deliberately conservative. A
row is marked `validated` only when the harness summary reports
`production_objective_validated=true`. Individual result rows without a final
summary can still report useful failure buckets such as
`proxy-active-but-timeout`, `proxy-activity-not-observed`,
`proxy-enabled-timeout`, `control-row`, or `throughput-signal-only`.

The local run id may be descriptive and long. The remote state id defaults to a
short generated value recorded in `manifest.env`, because QEMU shared-directory
helpers use UNIX sockets and those paths must stay below the kernel socket path
limit. Set `VPSADMINOS_TEST_OFFLOAD_REMOTE_RUN_ID` only when a specific short
remote path is needed.
