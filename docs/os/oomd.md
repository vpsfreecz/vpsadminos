# Container OOM daemon

`osctl-oomd` checks container memory, CPU and load every 15 seconds by default.
Its host-load gate compares the current load with a configured multiple of the
historical median. Candidates must meet the memory threshold, meet the CPU
threshold when a CPU limit is set, and fall within the configured load ranking.
The synthetic host row participates in that ranking.

At the default interval, eight hits request a restart and forty request a stop.
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
this option also enables `osctl.rtnlWatchdog`. Oomd uses ordinary JSON
`ct top` with network, ZFS, iostat and process collection disabled. A blocked
required read can still prevent a fresh sample. Oomd reads the local watchdog
state; its reaction does not depend on a Prometheus scrape or network request.

## Eligibility samples from ct top

```sh
osctl -j ct top --rate 15 --no-netif --no-zfs --no-iostat --no-processes
```

Ordinary `ct top` defaults to a one-second interval. Oomd supplies its configured
observation interval, normally 15 seconds. The same Top model serves JSON and
the interactive display. Network and ZFS collection are enabled by default;
`--no-netif` skips interface inventory, events and statistics, while `--no-zfs`
skips objset, ARC and iostat reads. The disabled JSON fields are null.

Top collects cgroup v1/v2 CPU and memory counters and limits, host
CPU/memory/load, and per-container load. It validates running inventory and init
PID/start identity around acquisition. Memory values are bytes; CPU usage keeps
Top's percentage-of-one-CPU convention and existing limit units. Unlimited
limits are null. The synthetic `[host]` row has a null pool and run identity and
participates in the full load ranking; it is never a container action target.

The enabled watchdog consumer requires `top_schema: 1` and effective
`collectors: {netif: false, zfs: false, iostat: false}`. Missing, malformed or
unexpected collector settings cannot authorize actions. This requirement
belongs to the consumer; ordinary Top can use any supported collector settings.
Frames include sampler-process `epoch`, increasing `sequence`, `complete` and
`invalid_reason`. Running container rows retain `pool`, `id`, `loadavg`,
`memory`, `memory_limit`, `cpu_usage` and `cpu_limit`, with `init_pid`,
`init_start_time_ticks`, `valid` and `invalid_reason` identifying usable runs.

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

Consumers must reject incomplete or invalid rows before interpreting
eligibility. Required read failures cannot certify zero activity. A blocked
required read prevents fresh publication; no replacement reader is launched.

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
gate. Invalid or incomplete samples, missing sequence numbers and sampler
replacement also clear accelerated evidence.

The sample freshness limit applies to acquisition and action dispatch. A hit
survives the normal fifteen-second observation interval. If the next valid
observation does not arrive within the interval plus the freshness limit,
accelerated
restart evidence clears without creating a miss. Same-run ordinary-mode scores
survive invalid gaps and sampler replacement; dispatch still requires a fresh,
complete current-run sample.

Settings under `osctl.oomd.settings.rtnl_watchdog`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Enable the additional host gate and guarded action path |
| `state_file` | `/run/rtnl-watchdog.json` | Root-owned schema 1 state file |
| `max_age_seconds` | `1` | Maximum watchdog frame age |
| `restart_hits` | `2` | Episode restart threshold, at least two |
| `observation_max_age_seconds` | `5` | Maximum sweep duration and sample age at dispatch |
| `action_workers` | `2` | Physical action slots, restricted to one or two |

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

Install the matching Top sampler, watchdog and guarded osctld/osctl commands
before enabling the option. Old or incomplete sampler output cannot authorize
feature actions. An older replacement daemon rejects guarded actions by command
name.

Disabling the option restores the original policy path and thresholds. It
requires no persistent score or database migration. The host-load history keeps
its existing format and cadence. Wait for outstanding actions to finish before
replacing the service: changing settings does not cancel a blocked command.
Follow the watchdog guide's lifetime-lock recovery rules when disabling or
replacing that service.
