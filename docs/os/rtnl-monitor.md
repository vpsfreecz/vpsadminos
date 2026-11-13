# RTNL waiter monitor

`osctl-rtnl-monitor` observes pending calls to the global blocking RTNL
acquisition wrappers. It helps diagnose contention affecting several containers.
It does not stop containers, change oomd policy, or identify the lock holder.
An affected container can be a victim of another task's lock hold.

## Enable on a host

The monitor is disabled by default. Enable it on a cgroup-v2 host:

```nix
{
  osctl.rtnlMonitor.enable = true;
}
```

The module runs two root-owned runit services:

- `osctl-rtnl-monitor-roots` refreshes container inventory every five seconds.
- `osctl-rtnl-monitor` owns the unpinned BPF attachments and emits snapshots.

Inventory uses the existing osctld client interface and checks running init
PID/start identity and cgroup membership. It does not collect network-interface
or ZFS data. It maps each container's base cgroup, including wrapper and payload
descendants. Nested container groups count as one container. A blocked inventory
process does not block the monitor or start replacement inventory workers.

Root inventory is schema 1 JSON, atomically replaced with mode `0600` at
`/run/osctl-rtnl-monitor/roots.json`. Run tokens remain stable across refreshes
and change when the init run or root identity changes. Failed or inconsistent
refreshes preserve the previous timestamp and inventory; they do not publish a
fresh empty snapshot. The monitor considers inventory stale after 30 seconds by
default. This runtime file has no persistent migration or recovery contract.

## Configure observations

The typed options mirror the production CLI:

| Option under `osctl.rtnlMonitor.settings` | Default | Meaning |
| --- | --- | --- |
| `intervalMs` | 1000 | Snapshot interval; 100 to 2000 ms |
| `waitMs` | 1000 | Minimum pending call age; 1 to 600000 ms |
| `minVps` | 3 | Distinct current roots required; 1 to 1024 |
| `confirmFrames` | 2 | Consecutive valid frames; 1 to 1000 |
| `maxPending` | 4096 | Fixed pending-task capacity; 1 to 65536 |
| `maxRoots` | 1024 | Root inventory capacity; 1 to 1024 |
| `mappingMaxAgeMs` | 30000 | Maximum inventory age; 100 to 3600000 ms |
| `stacks` | `"entry"` | Bounded entry-time sampling; `"off"` disables it |
| `metricsFile` | `"/run/metrics/osctl-rtnl-monitor.prom"` | Absolute textfile path owned exclusively by this monitor |

`osctl.rtnlMonitor.inventoryRefreshInterval` controls adapter refresh spacing
in seconds (default 5, range 1 to 60). `osctl.rtnlMonitor.package` selects a package
containing the executable, BPF object and adapter. The default package uses the
host's selected `boot.kernelPackage`; selecting another package also selects its
BPF object. The module does not allow an independent BPF-object override.

The default alarm requires at least three mapped container roots with a pending
call aged at least one second in two successive valid frames. These are
diagnostic settings, not kill thresholds. Full pending-map capacity, incomplete
required hooks, stale mappings, integrity loss or a frame gap above 2500 ms make
the assessment unknown and reset confirmation. Unknown alarms are JSON `null`,
and the Prometheus alarm series is omitted.

## Read results

The foreground service writes newline-delimited schema 1 JSON records through
existing runit logging and local syslog forwarding. Snapshots include attachment
epoch, sequence, availability, assessment validity, coverage, pending calls,
distinct mapped roots, oldest age, unmapped calls, mapping age and losses.
The bounded per-container array uses pool/container identity.

The monitor atomically replaces `/run/metrics/osctl-rtnl-monitor.prom`. Enable
the existing node-exporter textfile collector for `/run/metrics` to scrape it.
The monitor opens no HTTP listener. Metrics use the `osctl_rtnl_monitor_` prefix.
Check `available`, `assessment_valid` and `snapshot_timestamp_seconds` freshness
before interpreting counts or alarms. A crash can leave an old file; check its
age before treating it as a current health report. Pool/container IDs are bounded by
registered roots; task IDs, stack IDs and attachment epochs are not metric
labels.

Entry-time kernel stack sampling is bounded to four samples per 30 seconds,
at most one per container, with at most 32 frames and a fixed 256-entry stack
map. A sampled call may have completed before a later alarm. Stack records do
not prove the current blocked location or lock ownership. No synchronous
`/proc/*/stack` or `wchan` reads are needed for waiter tracking.

## Coverage and support limits

Coverage is `global_blocking_wrappers_v1`: entry and return of `rtnl_lock`,
`rtnl_lock_killable` and `refcount_dec_and_rtnl_lock`, plus task-exit cleanup.
The nonblocking `rtnl_trylock` and per-network/internal acquisition paths are
outside this coverage. Every snapshot reports `owner_supported=false`.
Pending age measures time inside the acquisition call, including spinning and
CPU preemption. It is not proven lock sleep time. Tasks already waiting before
attachment are a coverage gap, and a globally unresponsive host may delay all
observations. Unknown mappings are excluded from distinct-container counts.
Attribution uses the cgroup at entry, even if a task migrates afterwards.

The package builds native code, BPF object and generated BTF headers together.
It requires a supported Linux/BTF/helper/attachment environment and a host
cgroup-v2 hierarchy root. Missing required attachment targets fail visibly;
there is no silent probe fallback. Source configuration alone does not prove
the running kernel or generated BTF. Validate a candidate in disposable tests
against the selected kernel before enabling it on a host. No kernel rebuild
or machine deployment is performed by the monitor.

## Standalone use and removal

The selected package installs `bin/osctl-rtnl-monitor` and
`lib/osctl-rtnl-monitor/monitor.bpf.o`. The executable wrapper supplies that
object path. `--help` and `--version` do not attach. The standalone CLI accepts
`--roots-file`, `--bpf-object`, `--metrics-file` and the numeric/stack options
listed above. A trusted fixture can provide the same schema 1 root manifest.

Disable `osctl.rtnlMonitor.enable` through the normal configuration workflow to
stop both services. Closing the monitor's file descriptors detaches its links
and releases its maps; none are pinned. Service cleanup removes only its roots
manifest and configured metrics file. Existing containers, NFS behavior and
oomd settings are unchanged. Restoring an earlier configuration requires no
state conversion. Diagnostic output is not authorization for an automatic
container action.
