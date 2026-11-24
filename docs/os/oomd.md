# Container OOM daemon

`osctl-oomd` checks container memory, CPU and load at a configurable interval,
defaulting to five seconds. Either the host-load gate or the optional RTNL gate
can activate the same restart policy. Candidates must use at least 95% of a
finite memory limit, use at least 90% of their CPU limit when one is set, and
fall within the top five load readings. These thresholds are configurable.
The synthetic host row participates in the ranking but cannot be targeted.

Restart evidence accumulates in qualified seconds, with a default budget of
90 seconds. Stop escalation has a separate 600-second budget and requires the
host-load gate. Changing the sampling interval does not change either budget.

## Configure sampling and the load gate

Settings are under `osctl.oomd.settings`:

| Setting | Effective default | Meaning |
| --- | --- | --- |
| `interval` | `5` | Seconds between container observations |
| `load_enable` | `true` | Enable activation by host load |
| `load_multiplier` | `2.0` | Compare current load1 with this multiple of its historical median |
| `restart_after_seconds` | `90` | Shared qualified-time budget for a restart |
| `stop_after_seconds` | `600` | Qualified-time budget for a load-gated stop |
| `restart_unknown_expiry_seconds` | `30` | Clear restart evidence after this long without usable target and gate evidence |

The load gate opens when current load1 is at least the configured multiple of
its historical median. This threshold is relative to load history, not CPU
count. Both activation gates can be disabled independently; with both disabled,
oomd takes no action.

Durations are positive integers. Restart expiry must exceed the sampling
interval plus `rtnl_watchdog.observation_max_age_seconds`, whose default is five
seconds. The default expiry supports five- or fifteen-second sampling. For
thirty-second sampling, set a larger expiry explicitly, for example forty
seconds. Invalid combinations are rejected; no time budget scales silently.

The CLI provides `--interval`, `--load-enable true|false`, `--load-multiplier`,
`--restart-after-seconds`, `--stop-after-seconds` and
`--restart-unknown-expiry-seconds`.

## Enable the RTNL watchdog gate

The watchdog is a separate service. It can export Prometheus metrics without
activating oomd. See the [RTNL watchdog guide](rtnl-watchdog.md) for the probe,
metrics and lifetime-lock recovery rules.

To enable the additional RTNL activation gate:

```nix
{
  osctl.oomd = {
    enable = true;
    settings.rtnl_watchdog = {
      enable = true;
      latency_threshold_ms = 1000;
      sustain_seconds = 30;
      pending_seconds = 30;
    };
  };
}
```

`osctl.oomd.settings.rtnl_watchdog.enable` defaults to `false`. With oomd enabled,
this option also enables `services.rtnl-watchdog`. Oomd uses JSON `ct top`
with network, ZFS, iostat and process collection disabled. A blocked
required read can still prevent a fresh sample. Oomd reads the local watchdog
state; its reaction does not depend on a Prometheus scrape or network request.
The RTNL gate does not identify a responsible container. It uses the same
resource, ranking and current-run checks as load activation.

The gate opens on either of these conditions:

- Consecutive valid responses take strictly more than `latency_threshold_ms`,
  and their span from the first request's start to the latest completion is at
  least `sustain_seconds`. Only completed responses advance this span. Normal
  inter-probe scheduling gaps count while observer coverage remains continuous.
- The same announced probe remains pending for at least `pending_seconds` of
  continuous observer coverage. After an observer gap, it needs that much new
  coverage before it can activate the gate again.

A response at or below the cutoff clears the slow run, including a fast response
between oomd reads. Errors, helper changes and observation gaps also break the
proof. A retained last-duration value cannot establish sustained latency.
Missing or incompatible evidence disables RTNL activation with a diagnostic;
independently valid load protection continues.

The module matches the producer cutoff to the consumer setting. It requires
producer `intervalMs <= 1000` and `tickMs <= 250`; a conflicting cutoff or
unsupported cadence is rejected. Existing watchdog distress and overdue metrics
keep their separate `thresholdMs` setting.

Settings under `osctl.oomd.settings.rtnl_watchdog`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Enable the additional activation gate |
| `state_file` | `/run/rtnl-watchdog.json` | Root-owned schema 1 state file |
| `max_age_seconds` | `1` | Maximum watchdog frame age |
| `latency_threshold_ms` | `1000` | Strict cutoff for consecutive slow responses |
| `sustain_seconds` | `30` | Required completed slow-run span |
| `pending_seconds` | `30` | Required continuously observed pending age |
| `observation_max_age_seconds` | `5` | Maximum sweep duration and sample age at dispatch |
| `action_workers` | `2` | Physical action slots, restricted to one or two |

CLI forms are `--rtnl-enable true|false`, `--rtnl-latency-threshold-ms`,
`--rtnl-sustain-seconds` and `--rtnl-pending-seconds`.

## Eligibility samples from ct top

```sh
osctl -j ct top --rate 5 --no-netif --no-zfs --no-iostat --no-processes
```

Ordinary `ct top` defaults to a one-second interval. Oomd supplies its configured
observation interval, normally five seconds. Top enables network and ZFS
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
interval plus the freshness limit: ten seconds with both defaults. Consecutive
complete frames must link their CPU window to the preceding sweep. A stretched or inconsistent window is rejected even
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

## Qualified-time scoring

One restart score belongs to each verified container run. Its first usable
observation seeds the score without adding time. Linked fresh observations can
then add their covered monotonic elapsed time, capped at the configured
sampling interval. Both the activation gate and target eligibility must support
that interval. Watchdog heartbeats, repeated Top frames and missed samples add
no time, and a delayed collector cannot grant accumulated wall-clock backlog.

A decisive eligibility miss or confirmed gate inactivity subtracts covered time
at the same rate, with a floor of zero. Unknown input breaks the observation
link without granting credit or treating uncertainty as healthy decay. The next
usable observation seeds a new link. Without usable target and gate evidence for
`restart_unknown_expiry_seconds`, the restart score expires.

A fresh target sample alone does not refresh expiry when gate activation remains
unknown. Valid load activation remains usable when RTNL is unknown. When both
gates are known inactive, observations support bounded decay; a disabled gate
counts as inactive. RTNL activation with unknown load can support a restart but
cannot update the load-only stop score.

Switching between load and RTNL activation, or between probes, neither resets
nor accelerates the shared score. An interval without continuous gate proof is
omitted. Observer epoch changes invalidate RTNL proof but do not erase evidence
independently supported by load. From zero with load inactive, the default RTNL
gate first needs 30 seconds of qualifying latency or pending coverage, followed
by 90 qualified seconds of target evidence. Activation grants no retroactive
credit and does not guarantee an action at a wall-clock deadline.

Run replacement or disappearance, dispatch and terminal action completion clear
restart evidence. Dispatch always rechecks current eligibility, gate freshness
and run identity. Each new watchdog epoch needs two ordered fresh frames before
it can support activation.

Stop evidence remains separate. While the load gate is active, qualifying
observations add covered time and decisive misses subtract it. Inactive or
unknown load freezes the stop score. RTNL-only activation does not alter it.
The score survives a successful restart, clears after a successful stop, and
takes priority when both action budgets are met. Restart expiry does not apply
to stop history.

## Eligibility with partial samples

Oomd ranks the verified containers it can see alongside the synthetic host row.
It leaves a container out of the ranking while its restart or stop is pending,
even if osctld still lists the container as running. Other containers can earn
qualified time and use a free worker throughout that time.

On a partial sample, each target needs fresh memory and limit readings and a
CPU measurement from two adjacent sweeps of the same run. If a load reading is
missing from the ranking, oomd scores a target only when that reading cannot
change whether it falls inside the configured top group.

When the ordinary host-load gate is open, partial observations update both
restart and stop scores. A stop takes priority when both thresholds are met.
RTNL activation alone can grant a restart. A stop always requires the
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

Decision records include gate reasons, host load and median, resource values
and limits, rank, covered time, scores and budgets, run and sample identities,
and action outcomes. These records help explain a decision; missing logs cannot
authorize an action or establish that no action occurred.

## Settings and metric migration

Legacy `restart_hits` and `stop_hits` settings are accepted with a warning.
They convert to seconds by multiplying by an explicitly supplied interval, or
by the historical fifteen-second interval when none was supplied. For example,
`restart_hits = 4` without `interval` becomes a 60-second restart budget.
Sampling still defaults to five seconds. This preserves the nominal budget,
not the exact timing of the former first hit. Supplying both a legacy setting
and its corresponding seconds setting is an error.

The former `rtnl_watchdog.restart_hits` setting has no accelerated replacement.
When RTNL is disabled, an explicit legacy value produces a warning and is
ignored. When RTNL is enabled, remove that setting and configure the shared
seconds budget before starting oomd.

The exporter uses explicit seconds metrics:

| Former metric | Replacement |
| --- | --- |
| `osctl_oomd_restart_hits` | `osctl_oomd_restart_after_seconds` |
| `osctl_oomd_stop_hits` | `osctl_oomd_stop_after_seconds` |
| `osctl_oomd_container_restart_hits` | `osctl_oomd_container_restart_qualified_seconds` |
| `osctl_oomd_container_stop_hits` | `osctl_oomd_container_stop_qualified_seconds` |

Update dashboards and alerts to use the new names and units. Old and new oomd
versions expose different metric families during a rolling update; seconds are
never exported under hit names.

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

Update the watchdog producer before activating the new RTNL consumer policy.
An older consumer ignores the additive schema-1 latency summary. A new consumer
with an older producer keeps load protection available and disables RTNL
activation with a diagnostic. Nodes can be updated independently; no shared
score state requires a coordinated fleet switch.

For rollback, disable RTNL activation first or restore matching OS binaries and
configuration together. An older oomd needs its old settings rather than the
new seconds keys. Scores are held in memory, so no on-disk score conversion is
needed. Dry-run suppresses actions from both gates; it cannot shadow RTNL while
leaving ordinary protection active.
