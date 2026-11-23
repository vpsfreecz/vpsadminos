# Container OOM daemon

`osctl-oomd` checks container memory, CPU and load every 15 seconds by default.
Its host-load gate compares the current load with a configured multiple of the
historical median. Candidates must meet the memory threshold, meet the CPU
threshold when a CPU limit is set, and fall within the configured load ranking.
The synthetic host row participates in that ranking.

By default, the ordinary policy requires eight hits for a restart and forty
for a stop. Both thresholds are configurable.
A qualifying observation adds one to a score; a miss subtracts one, with a floor
of zero. An inactive host gate leaves scores unchanged.

## Enable the RTNL watchdog gate

The watchdog is a separate service. It can export Prometheus metrics without
activating oomd. See the [RTNL watchdog guide](rtnl-watchdog.md) for the probe,
metrics and lifetime-lock recovery rules.

To let oomd react to watchdog distress:

```nix
{
  osctl.oomd = {
    enable = true;
    settings.rtnl_watchdog.enable = true;
  };
}
```

`osctl.oomd.settings.rtnl_watchdog.enable` defaults to `false`. With oomd enabled,
this option also enables `services.rtnl-watchdog`. Oomd uses JSON `ct top`
with network, ZFS, iostat and process collection disabled. A blocked
required read can still prevent a fresh sample. Oomd reads the local watchdog
state; its reaction does not depend on a Prometheus scrape or network request.

## Eligibility samples from ct top

```sh
osctl -j ct top --rate 15 --no-netif --no-zfs --no-iostat --no-processes
```

Ordinary `ct top` defaults to a one-second interval. Oomd supplies its configured
observation interval, normally 15 seconds. Top enables network and ZFS
collection by default. `--no-netif` skips interface inventory, events and
statistics. `--no-zfs` skips objset, ARC and iostat reads. Disabled collectors
provide no readings.

Top collects cgroup v1/v2 CPU and memory counters and limits, host
CPU/memory/load, and per-container load. It validates running inventory and init
PID/start identity around acquisition. Memory values are bytes; CPU usage keeps
Top's percentage-of-one-CPU convention and existing limit units. Unlimited
limits are null. The synthetic `[host]` row has a null pool and run identity and
participates in the full load ranking; it is never a container action target.

Oomd reads one bounded JSON stream. Each record must have `top_schema: 2` at
the root and `collectors: {netif: false, zfs: false, iostat: false}`. This
changes the output format of `osctl -j ct top`. Oomd rejects schema 1, wrapped
records, malformed records and unexpected collector settings. Ordinary
`ct top` still supports its own collector settings.

Each record identifies the acquisition by `epoch` and `sequence` and carries
verified container runs and individual CPU measurement windows. After a missed
or invalid record within a sampler run, oomd waits for a fresh compatible pair
before acting again.

`sample_started_monotonic_ns` and `sample_completed_monotonic_ns` enclose the
current acquisition and projection. `measurement_window_started_monotonic_ns`
is the preceding coherent same-run raw sweep's start;
`measurement_window_completed_monotonic_ns` is the current sweep's completion.
These host-monotonic timestamps enclose the CPU reads rather than timestamping
each counter read exactly. Serialization and redraw do not advance the sequence
or refresh the sample's age.

Oomd checks current-sweep duration and age since completion separately. Each is
limited by `observation_max_age_seconds`, which defaults to five seconds. The
CPU envelope may span the observation interval, but must fit within that
interval plus the freshness limit: twenty seconds with both defaults. Consecutive complete frames must link their CPU window
to the preceding sweep. A stretched or inconsistent window is rejected even
when its latest completion is recent.

Missing or inconsistent core input makes a snapshot incomplete. A failed sweep
discards its baseline. A coherent raw sweep without a compatible baseline seeds
the next delta and remains incomplete; counter resets and run changes also
require a fresh baseline. Setup takes an unpublished seed, so the first visible
complete frame can use that seed. Disabled optional collectors do not invalidate
coherent core data, and unavailable optional values are null.

With network and ZFS collection disabled, JSON Top allows one outstanding
container inventory request. If osctld is slow to answer, Top uses the last
list to find known containers and marks the inventory incomplete. It reads
their current counters and checks their init processes at both ends of each
sweep. It can discover new containers once osctld answers. A blocked local
counter read can still delay publication beyond the freshness limit.

## Scoring during watchdog distress

Fresh watchdog distress opens the host gate independently of loadavg. It does
not identify the responsible container. The existing memory, CPU and ranking
checks still apply.

Each distress episode starts with cleared restart evidence. The episode restart
threshold defaults to two. Only distinct qualifying observations whose sweeps
began after episode entry add hits. Misses subtract one from restart evidence;
watchdog heartbeats and duplicate samples do not add hits. The original
loadavg-gated policy continues to update the stop score, including its default
forty-hit threshold. Watchdog-only observations never increase or decrease it.

A fresh healthy completion, stale or erroneous watchdog state, or an observer
epoch change removes the override and clears accelerated restart evidence.
Each new watchdog epoch needs two ordered fresh frames before it can open the
gate. Invalid packets, missing sequence numbers and sampler replacement also
clear accelerated evidence. A valid partial observation can still support a
hit for a verified run. An undecidable observation clears accelerated
restart evidence for that run only.

The sample freshness limit applies to acquisition and action dispatch. A hit
survives the normal fifteen-second observation interval. If the next valid
observation does not arrive within the interval plus the freshness limit,
accelerated restart evidence clears without creating a miss. Same-run ordinary-mode scores
survive invalid gaps and sampler replacement. Dispatch still requires fresh
measurements from the current run.

Settings under `osctl.oomd.settings.rtnl_watchdog`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Enable the additional host gate |
| `state_file` | `/run/rtnl-watchdog.json` | Root-owned schema 1 state file |
| `max_age_seconds` | `1` | Maximum watchdog frame age |
| `restart_hits` | `2` | Episode restart threshold, at least two |
| `observation_max_age_seconds` | `5` | Maximum sweep duration and sample age at dispatch |
| `action_workers` | `2` | Physical action slots, restricted to one or two |

## Eligibility with partial samples

Oomd ranks the verified containers it can see alongside the synthetic host row.
It leaves a container out of the ranking while its restart or stop is pending,
even if osctld still lists the container as running. Other containers can earn
hits and use a free worker throughout that time.

On a partial sample, each target needs fresh memory and limit readings and a
CPU measurement from two adjacent sweeps of the same run. If a load reading is
missing from the ranking, oomd scores a target only when that reading cannot
change whether it falls inside the configured top group.

When the ordinary host-load gate is open, partial observations update both
restart and stop scores. A stop takes priority when both thresholds are met.
Watchdog distress alone can grant a restart. A stop always requires the
host-load gate.

For a partial sample, oomd compares the current host load with the median that
would result from adding it to the complete history. Only complete observations
update the persisted history. On a cold node, oomd keeps a bounded history of
measured host loads in memory. It needs at least two readings to evaluate the
gate and drops this temporary history when it gets a strict baseline or the
sampler restarts.

## Guarded actions

One controller owns scores and action reservations. Two command slots allow
another eligible container to proceed while one action blocks. A busy slot does
not accumulate authorized commands. A subsequent fresh observation must pass
the host gate, eligibility, age and run checks again. Each container has at most
one action in flight. A successful restart retains its stop history. Completion
or rejection requires new raw evidence before another action.

`osctl ct oomd-restart` and `osctl ct oomd-stop` require both
`--expected-init-pid` and `--expected-init-start-time`. The latter uses raw
process start ticks. The daemon checks them under the container manipulation
lock before entering the existing force-kill lifecycle. A request that waits for
the lock checks the run after acquiring it. Ordinary stop and restart commands
are unchanged. Old daemons reject the new command names; there is no fallback
to an ordinary command.

After validation the daemon emits `OOMd expected run accepted pid=… start=…`.
Oomd sends the same guarded daemon requests through the existing client API.
Only a definitive terminal daemon response establishes completion. EOF,
transport errors and protocol uncertainty leave the outcome unknown. Guard acceptance, payload EXIT and
command completion are separate events.

NFS cancellation, freezing, force-kill and cleanup retain their existing order.
Shared kernel or NFS locks can block both slots indefinitely. A deadline does
not free a slot or establish cancellation. An unknown command outcome keeps its
slot and reservation held and does not trigger automatic retries. Shutdown
stops new actions and waits for outstanding work.

Event broadcast and policy logging use a separate worker with a sixteen-event
queue. Notification failure does not retry an action. Queue overflow and
failure appear as `osctl_oomd_notification_drops` and
`osctl_oomd_notification_failures`; uncertain effects appear as
`osctl_oomd_unknown_actions`. The existing textfile exporter publishes these
metrics. A blocked notification worker cannot retain a completed action slot.

## Compatibility and rollback

Use schema-2 Top and oomd from the same release, with an osctld that supports
the guarded commands. Do not connect an older oomd to schema-2 Top. An older
daemon without the guarded commands rejects requests; oomd does not retry them
as ordinary actions. Oomd and the watchdog remain off unless enabled.

Stop oomd and the other Top JSON readers before switching binaries. Verify
that outstanding actions have finished and reconcile any unknown outcomes
before starting the new oomd. Replacing the sampler does not cancel a blocked
command.

Use `--dry-run` to check what oomd would restart or stop. In either gate mode,
it logs simulated decisions without sending action commands or broadcasting
action-success events. Sampling, scoring, metrics and host-load history still
run.

To roll back, stop the readers again and drain or reconcile any outstanding
actions. Restore the previous matching Top and readers together before starting
them. Check the older oomd's safeguards: older ordinary oomd did not use the
run guard. The host-load history format is unchanged. No migration is required.
