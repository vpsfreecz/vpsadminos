# RTNL responsiveness watchdog

`rtnl-watchdog` measures responsiveness of a small request through the
global RTNL path. It runs independently of oomd and does not identify a lock
holder, select containers or take container actions. See the
[oomd reference](oomd.md) for the optional consumer policy and guarded actions.

The service is disabled by default. Enable its standalone diagnostics with:

```nix
{
  services.rtnl-watchdog.enable = true;
}
```

The root-owned service uses one observer, one persistent private probe helper
and one bounded output worker. The helper performs a non-dump `RTM_GETLINK`
request with no interface selector or attributes. On the supported kernel this
path takes global RTNL and returns the deliberately expected `EINVAL` before
device lookup and response filling. Only a kernel response matching the
request sequence, type and expected error is a valid completion. A successful
send alone is insufficient.

Both binaries are written in Rust, with Linux syscall bindings isolated in a
small module. Before starting worker threads, the observer marks descriptors
3 and above close-on-exec. Startup fails if it cannot establish that policy.
Rust ownership does not guarantee progress in a kernel call.

The private helper receives duplex IPC on stdin (FD 0) and the inherited
lifetime lock on stdout (FD 1). It never writes or logs to stdout; stderr goes
to `/dev/null`. Closing a local descriptor, receiving EOF or losing the
observer does not cancel a pending request.

The helper must share the host init network namespace and cannot switch
namespaces. The module runs in the ordinary host service context; standalone
use also requires that context. Generic socket, acknowledgement, scheduling
and unlock work are included in the duration. This measures request
responsiveness rather than exact mutex sleep time. Kernel support must be
verified with the selected kernel; an unexpected response is an error. The
expected error alone does not prove global-lock coverage on an unexamined
kernel version.

## Settings

All options below are under `services.rtnl-watchdog.settings`:

| Option | Default | Supported range |
| --- | --- | --- |
| `intervalMs` | 1000 | 100 to 60000 ms |
| `thresholdMs` | 1000 | 100 to 60000 ms; at least `tickMs` |
| `latencyThresholdMs` | 1000 | 1 to 60000 ms; cutoff for the consumer's slow-response summary |
| `tickMs` | 250 | 50 to 1000 ms |
| `errorBackoffMs` | 5000 | 100 to 3600000 ms |
| `metricsFile` | `/run/metrics/rtnl-watchdog.prom` | Absolute file path |

The observer admits no backlog or overlapping request. The next probe waits
at least `intervalMs` after completion; completed errors wait the larger of
that interval and `errorBackoffMs`. While an announced request remains pending,
its age crossing `thresholdMs` produces distress. The first probe can become
distressed before any successful response. A missing start acknowledgement
remains unknown, regardless of dispatch age. A matched valid completion clears
the current distress immediately and retains its full duration.

The CLI mirrors these settings with `--interval-ms`, `--threshold-ms`,
`--latency-threshold-ms`, `--tick-ms`, `--error-backoff-ms` and `--metrics-file`.
Standalone fixtures can also set `--state-file`, `--exposure-file` and
`--lock-file`; the module fixes those paths below.
Paths must be absolute and normalized, with distinct state, metrics, exposure
cache and lock files in trusted root-owned directories. `--help` and `--version` do not probe.
`services.rtnl-watchdog.package` selects a package containing the observer and its
private helper; the helper is resolved from that package, never from PATH or a
configurable backend.

## State and freshness

The authoritative consumer file is `/run/rtnl-watchdog.json`, atomically
replaced with root ownership and mode `0600`, limited to 4096 bytes. Schema 1
fields are `schema`, `boot_id`, `epoch`, `sequence`, `observed_monotonic_ns`,
`probe_sequence`, `state`, `dispatch_monotonic_ns`, `started_monotonic_ns`,
`completed_monotonic_ns`, `last_duration_ns`, `expected_errno` and `error_code`.
Unset timestamps/durations are null. Historical last valid duration remains
available while a subsequent request is pending. `expected_errno` is 22.
`error_code` is 0 for none, 1 for namespace, 2 for socket, 3 for send, 4 for
receive, 5 for reply, 6 for IPC and 7 for helper failure. Status logs include
observer/helper PIDs, epoch and reason.

States are `starting`, `pending`, `distressed`, `healthy` and `error`.
`distressed` requires a received start acknowledgement and an overdue pending
request; the acknowledgement does not prove the syscall has reached RTNL.
`healthy` requires the matched expected response. Namespace/protocol/helper
errors remain unknown. Consumers validate root ownership/mode, framing,
boot/epoch/ordered sequence and monotonic freshness. Oomd requires two ordered
fresh frames to bind a new epoch and expires evidence after one second. Old,
future or missing state cannot authorize its watchdog override.

Schema 1 also contains an additive `latency_run` object for sustained-latency
consumers. Its `version` is 1. The fixed-size fields are `cutoff_ns`,
`interval_ns`, `tick_ns`, `coverage_started_ns`, `valid`, `first_probe`,
`last_probe`, `first_started_ns`, `last_completed_ns` and `slow_count`.
An empty run has null probe identities and timestamps and a zero count.
`valid` describes continuous observer coverage, including normal scheduling
gaps; it starts false.

Every matched completion updates this summary before output coalescing. A
successful response strictly above `latencyThresholdMs` starts or extends the
consecutive slow run. A response at or below the cutoff clears it, even when
no consumer reads the intervening frame. The span ends at the latest slow
completion and cannot grow from a retained duration or a pending probe alone.
This cutoff is independent of `thresholdMs` and changes no histogram or
overdue-counter semantics.

Errors, helper changes and observer discontinuities clear the summary.
Before processing queued IPC, the observer resets coverage after a loop gap
over one second, a dispatch more than one second past its scheduled deadline,
or a missing start acknowledgement past its one-second grace. A completion
whose start predates the new coverage boundary cannot seed a slow run.
An already announced pending probe can regain coverage after queued messages
are processed, but its consumer age starts at the later of its original start
and the new coverage boundary. This does not cancel or replace the helper.

Oomd validates the summary version, configured cutoff, supported cadence and
freshness. Its control path requires `intervalMs <= 1000` and `tickMs <= 250`.
A missing or mismatched summary disables RTNL activation while independently
valid load protection remains available. Older consumers ignore the added
fields. See the [oomd reference](oomd.md) for activation durations and rollout
compatibility.

## Exposure observation cache

The observer also publishes `/run/rtnl-watchdog-exposure.json` atomically with
root ownership and mode `0600`. This separate schema-1 file is limited to 32768
bytes including its newline. The primary state file keeps its 4096-byte limit.
The cache contains the last 128 terminal observations in order, including fast
responses and errors, plus the current pending probe. The observer model retains
the ring before output snapshots coalesce, so short completions remain available
between consumer reads. It is an in-memory observation cache, not a delivery log.

Fields are `schema`, `boot_id`, `epoch`, `observed_monotonic_ns`, `cutoff_ns`,
`interval_ns`, `coverage_started_ns`, `coverage_valid`, `paused`, `first_sequence`,
`last_sequence`, `records` and `pending`. Times use unsigned 64-bit nanoseconds.
Each terminal record is a fixed tuple:

```text
[sequence, probe, started_ns_or_null, completed_ns, error_code,
 coverage_started_ns_or_null, coverage_valid]
```

`pending` is null or an object containing `probe`, `started_ns_or_null`,
`coverage_started_ns_or_null` and `coverage_valid`. An empty ring has first and last
sequence zero. Each terminal advances the sequence, including failed probes.
Helper or observer epoch changes reset the ring. Coverage describes only the
observed suffix after `coverage_started_ns`; it cannot repair an earlier gap in
a long pending probe.

Consumers validate ownership, framing, bounds, boot/epoch identity, cutoff,
freshness and sequence continuity against the primary state. Missing or
overwritten terminals require a new baseline. Old producers, missing files,
errors and paused coverage remain unknown evidence. The existing output worker
writes the bounded cache; a stalled writer can leave it stale. See
[oomd exposure collection](oomd.md#collect-rtnl-exposure-events) for interval
accounting and the separate best-effort event path.

## Ordered probe evidence

The producer writes JSON records for probe dispatch, start and every completion,
including fast responses, plus errors, helper lifecycle and coverage changes.
These records enter an ordered FIFO before current-state snapshots can coalesce.
Each record carries an evidence-schema version, process epoch, event sequence,
boot/probe identity, timestamps, duration/error and the observer's coverage state.
A retained last-duration gauge or histogram cannot replace this ordering when
evaluating consecutive slow responses.

The state file also has an additive `log_evidence` object with `version: 1` and
`state` equal to `ready`, `backpressured` or `draining`. It reports support and
pipeline state only. `ready` does not prove that a record was written, retained
or received centrally. Missing, unsupported or malformed markers leave ordered
log support unverified. The existing latency summary alone does not establish
support. Oomd reports this diagnostic independently of RTNL policy enable;
marker absence does not invalidate otherwise valid existing control evidence.
Older consumers ignore the added object.

The evidence FIFO holds at most 256 records and 1 MiB of payload, including
writer-owned records and reservations. It reserves four records before admitting
a probe and keeps eight lifecycle records available. When capacity is
unavailable, the observer pauses new probe admission and invalidates control
coverage. It continues handling an already-announced probe through reserved
capacity; logging pressure never cancels or replaces the helper. Pause and
resume records delimit a gap. Recovery starts new coverage and cannot grant
retroactive sustained-latency credit.

The existing output worker retains the FIFO head and its partial-write offset
on blocked or failed stdout writes. Nonblocking retries leave it available for
current state/metrics output. Application records are at most 3072 bytes. A
complete local write releases evidence capacity; it does not establish disk
durability or remote receipt. Graceful shutdown stops admissions and drains
accepted evidence. A blocked sink can keep shutdown pending; forced termination
or a crash can lose in-memory records.

The service logs to `/var/log/rtnl-watchdog` and forwards to `127.0.0.1:514` over
UDP. Its inherited runit defaults rotate at 1000000 bytes and keep ten old files
plus the current file, without age-driven rotation. This gives roughly 10 MB
of rotated logs, not a fixed retention period. With the default one-second
spacing, dispatch/start/completion produce approximately three records per
second for fast probes, plus lifecycle and coverage records. Larger records
and event bursts shorten retention. Local disk failure, rotation and UDP loss
remain limits; there is no durable spool or guaranteed central receipt.

Compare alternate RTNL latency/sustain thresholds only where the retained stream
has complete sequence and coverage. Missing records, pauses and observer gaps
leave that interval unknown. See [oomd decision evidence](oomd.md#continuous-decision-evidence)
for the independently sampled host signals and candidate VPSes.

## Prometheus output

Use the existing node-exporter textfile collector for the configured directory.
The watchdog opens no HTTP listener. Metrics use `rtnl_watchdog_`:
`available`, `distress`, `pending_age_seconds`, `last_probe_duration_seconds`,
`last_success_timestamp_seconds`, `snapshot_timestamp_seconds`, `errors_total`
and `output_errors_total`. Unknown distress is omitted; last duration/success
are omitted until a valid completion. Check freshness and availability before
interpreting them.

`output_errors_total` counts failures to render or write state, metrics, the
exposure cache or status output, including output rejected by a size limit. Replacing an older
queued state/metrics snapshot with the newest one does not increment it.
The counter resets when the observer restarts. Alert on new failures and stale
`snapshot_timestamp_seconds` values rather than a positive lifetime total:
a past error can remain visible after publication has recovered. A failed
metrics write can only be reported through a later successful publication.

Older implementations also count queued-output replacements as output errors.
During a mixed-version rollout, interpret this counter per node with that
difference in mind.

`response_duration_seconds` is a histogram of valid completed responses. Its
fixed bucket limits are 0.001, 0.01, 0.1, 0.25, 0.5, 0.75, 1, 2, 3, 4, 5,
6, 7, 8, 9, 10, 15, 20, 25, 30, 40, 50, 60, 90, 120, 300, 600 and +Inf
seconds, with count and sum series. Buckets are cumulative: each `le` bucket
counts responses less than or equal to its limit. It records only
matched expected-EINVAL completions. `overdue_probes_total` counts each announced
probe once at an observed pending threshold crossing or a late completion,
including timed errors; missing-start dispatches are excluded. These aggregates
retain short stalls between scrapes even when the last-duration gauge is later
overwritten. They persist across helper recreation and reset with the observer
process, as ordinary Prometheus process counters do. A restart before a scrape
can lose measurements not yet collected. Only histogram `le` labels
are used; detailed bounded error reasons belong in logs.

When aggregating histograms across nodes, use matching bucket boundaries.
During a rollout with different bucket sets, query each node separately or
restrict aggregation to the boundaries shared by all selected nodes.

State/metric output uses a fixed latest-frame handoff. Coalesced frames retain
observer-owned histogram/counters; ordered probe evidence uses the separate FIFO
described above. A blocked filesystem writer can leave the published files stale and
prevent the same worker draining evidence. Once evidence capacity fills, new
probes pause while outstanding helper work remains accounted for. No unlimited
worker pool replaces the writer. Host scheduler or memory stalls can also delay
observation. There is no guaranteed alarm deadline during a global stall.

## Stop and recovery

An exclusive lock at `/run/rtnl-watchdog.lock` is inherited by the helper
across exec. The module uses runit's process-only stop mode. If the observer
dies while a helper is blocked, that helper retains the lock and a replacement
observer fails visibly instead of launching another probe. The lock file is
never unlinked or recreated as a deadline or shutdown mechanism.

Normal shutdown stops admissions and closes IPC; the helper exits after its
outstanding call returns and detects the closed connection. No cancellation is
claimed. After a known reaped helper failure, recreation waits the error backoff
and starts a new epoch. A child with uncertain effects is never replaced.
Clean observer shutdown removes only its own state, metrics and exposure cache
after the writer exits. A crash or stalled writer can leave stale output; consumers must enforce
freshness. Do not delete the lifetime lock or force a second probe during
recovery. Disabling the service changes no persistent schema or container
lifecycle, and oomd consumer policy remains separately controlled.
