# Container state history

`osctl ct state-history` shows container states observed during the current host
boot. It combines a bounded recent timeline with first-running evidence retained
for each pool and container ID until the host reboots. It covers automatic and
manual starts; a running observation does not establish application health.

```shell
osctl ct state-history
osctl --json ct state-history --pool tank myct01
osctl --json ct state-history --ever-running
```

The optional ID requires an explicit pool. Both the global `--pool` and the
command-local `--pool` work; the local value takes precedence. Put options before
the ID. Filters apply to saved identities, so deleted containers and exported
pools remain queryable without live container objects.

## Timeline and first-running evidence

Each event contains a global `sequence`, `boottime_seconds`, `pool`, `id`, `kind`
and `state`. Sequence orders recorder acceptance; timestamps use
`CLOCK_BOOTTIME`, in seconds since kernel boot. They do not establish the exact
physical ordering of concurrent LXC transitions.

`kind: state` records an accepted managed state. For example, completing a
staged container records its effective `stopped` state. An ignored staged
assignment does not create a state event. `kind: observation` records an actual
LXC sample refused by the existing error/staged management guards; it leaves
quarantine intact. Accepted LXC samples produce a state event alone. Each kind
suppresses successive identical samples independently, including after restart.

Publishing a container in osctld records its initial managed state, except
`running`: a loaded configuration value cannot prove running. Constructors and
temporary clones do not record these initial samples. Pool import queries every
loaded container; quarantined containers retain their managed state and record the actual sample
separately. Recovery's synthetic Eventd notifications do not become events.

The first actual `running` sample from either kind is retained for the whole
boot. Stopping/deleting a container, exporting its pool, evicting timeline events
or restarting osctld does not remove it. Reusing the same ID in the same pool
shares evidence until reboot. Moving to another pool or node does not move it.
Summary storage therefore grows with unique identities observed in this boot.

After downtime, osctld records a changed current state at its observation time.
An unchanged state adds no restart event. Intermediate transitions are neither
invented nor backdated: a start and stop entirely while osctld and its monitors
are absent cannot be recovered. External LXC control has the same observation
limit. There is no additional poller or Eventd history subscriber.

The history is independent of the autostart scheduler. `started-cts.txt` can
record an attempt before startup succeeds. Queue completion, retry exhaustion
and successful start-command dispatch do not prove that LXC reached running.

## Configuration

The host-wide recent-event limit defaults to 1000. Configure an integer from
1 through 10000 in the existing osctld settings:

```nix
osctld.settings.state_history.max_events = 1000;
```

The corresponding osctld JSON is `{"state_history":{"max_events":1000}}`.
Strings, booleans, fractional values and values outside the range are rejected.
The limit takes effect on daemon restart. Lowering it atomically evicts the
oldest events during load; raising it cannot restore events already dropped.
There is no disabled or unlimited setting. Eviction never removes summaries or
first-running evidence. Human timeline output reports truncation explicitly.

## Query contract

The daemon command `ct_state_history` accepts `cli`, `view`, `pool` and `id`.
`view` is `timeline` by default or `ever_running`. Unknown options/views,
malformed identities and an ID without a pool are rejected. Pool names use the
existing alphanumeric-first pool grammar; container IDs accept 1 to 100 letters,
digits, underscores or hyphens, including initial underscores/hyphens.

The usual osctld command envelope contains this timeline payload:

```json
{
  "schema_version": 1,
  "boot_id": "00000000-0000-4000-8000-000000000001",
  "available": true,
  "reason": null,
  "entries": [
    {"pool": "tank", "id": "myct01", "first_running_boottime_seconds": 21.5,
     "last_state": "running", "last_observation": null}
  ],
  "max_events": 1000,
  "dropped_events": 0,
  "truncated": false,
  "events": [
    {"sequence": 1, "boottime_seconds": 21.5, "pool": "tank", "id": "myct01",
     "kind": "state", "state": "running"}
  ]
}
```

Summaries are unique and sorted by `(pool,id)`. Nullable fields mean there has
been no sample of that kind or no running proof. Events are the retained global
suffix in sequence order. `dropped_events` counts all evictions; cap, count and
truncation remain global when filters are used.

`--ever-running` requests the compact first-running projection. Its payload has
exactly these five keys and contains only identities with running proof:

```json
{
  "schema_version": 1,
  "boot_id": "00000000-0000-4000-8000-000000000001",
  "available": true,
  "reason": null,
  "entries": [
    {"pool": "tank", "id": "myct01", "first_running_boottime_seconds": 21.5}
  ]
}
```

Consumers must validate schema, kernel boot ID, availability and entries. The
compact view uses full-boot summaries and is unaffected by timeline truncation.

## Persistence and unavailable history

The root-only `/run/osctl/container-state-history.json` stores schema version,
boot ID, next sequence, dropped count, summaries and recent events in one file.
Recording serializes sequence/time assignment, deduplication, summary updates,
eviction and atomic Tempfile write/flush/fsync/rename. New data becomes queryable
only after that write succeeds. Container assignment and recording share the
container lock, with container-to-history lock order. Synchronous filesystem I/O
can delay state handling; there is no I/O deadline or asynchronous writer.

The boot hook creates an empty record before runit. Ordinary service startup,
pool operations and system activation never create or reset it. A real host
boot starts new history and clears the failure sentinel. The built system
publishes `/etc/osctl/container-state-history-version` with value `1`; osctld
checks it through `/run/booted-system/etc/`. A live upgrade on a system booted
without support therefore reports `awaiting_reboot` until a normal reboot.

Unavailable queries still succeed at the command-envelope level, with
`available:false`, empty entries and one of these reasons:

| Reason | Meaning |
| --- | --- |
| `awaiting_reboot` | No record exists and the system booted without history support. |
| `state_missing` | The record is missing from a capable boot or was lost during uptime. |
| `state_invalid` | The record cannot be read or fails exact schema/content validation. |
| `boot_id_mismatch` | The record belongs to another kernel boot. |
| `persistence_failed` | A sample or cap reduction could not be saved. |

Unavailable timeline responses also have empty events, the configured cap and
null `dropped_events`/`truncated`; unknown history is not presented as complete.
The compact response retains its five-key shape. Errors are logged and leave
container control available. Restart does not replace missing or invalid state.

Caught persistence failures latch history unavailable. osctld tries to rename
the prior snapshot to `/run/osctl/container-state-history.failed.json`, then
exclusive sentinel creation, then invalidation of the normal file. Any sentinel
path, including empty, malformed, unreadable or dangling paths, takes precedence
over a normal record and survives daemon restart. Only boot initialization clears
it. If the filesystem refuses every mutation, osctld logs that a durable failure
latch could not be established. Abrupt process loss before the failure handler
can lose an unpersisted sample; this is not a complete audit or power-loss journal.

Nodes can adopt the feature independently; no coordinated fleet update is
required. Older osctld versions ignore this separate runtime record. Container
configuration and scheduler formats retain their existing contracts. Consumers
must treat unsupported/unavailable history as missing evidence. Deleting files
is not a repair for an unresolved startup or persistence failure.
