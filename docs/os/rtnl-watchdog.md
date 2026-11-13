# RTNL responsiveness watchdog

`rtnl-watchdog` measures responsiveness of a small request through the
global RTNL path. It runs independently of oomd and does not identify a lock
holder, select containers or take container actions. See the
[oomd reference](oomd.md) for the optional consumer policy and guarded actions.

The service is disabled by default. Enable its standalone diagnostics with:

```nix
{
  osctl.rtnlWatchdog.enable = true;
}
```

The root-owned service uses one observer, one persistent private probe helper
and one bounded output worker. The helper performs a non-dump `RTM_GETLINK`
request with no interface selector or attributes. On the supported kernel this
path takes global RTNL and returns the deliberately expected `EINVAL` before
device lookup and response filling. Only a kernel response matching the
request sequence, type and expected error is a valid completion. A successful
send alone is insufficient.

The helper must share the host init network namespace and cannot switch
namespaces. The module runs in the ordinary host service context; standalone
use also requires that context. Generic socket, acknowledgement, scheduling
and unlock work are included in the duration. This measures request
responsiveness rather than exact mutex sleep time. Kernel support must be
verified with the selected kernel; an unexpected response is an error. The
expected error alone does not prove global-lock coverage on an unexamined
kernel version.

## Settings

All options below are under `osctl.rtnlWatchdog.settings`:

| Option | Default | Supported range |
| --- | --- | --- |
| `intervalMs` | 1000 | 100 to 60000 ms |
| `thresholdMs` | 1000 | 100 to 60000 ms; at least `tickMs` |
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
`--tick-ms`, `--error-backoff-ms` and `--metrics-file`. Standalone fixtures can
also set `--state-file` and `--lock-file`; the module fixes those paths below.
Paths must be absolute and normalized, with distinct state, metrics and lock
files in trusted root-owned directories. `--help` and `--version` do not probe.
`osctl.rtnlWatchdog.package` selects a package containing the observer and its
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

## Prometheus output

Use the existing node-exporter textfile collector for the configured directory.
The watchdog opens no HTTP listener. Metrics use `rtnl_watchdog_`:
`available`, `distress`, `pending_age_seconds`, `last_probe_duration_seconds`,
`last_success_timestamp_seconds`, `snapshot_timestamp_seconds`, `errors_total`
and `output_errors_total`. Unknown distress is omitted; last duration/success
are omitted until a valid completion. Check freshness and availability before
interpreting them.

`response_duration_seconds` is a histogram of valid completed responses. Its
fixed bucket limits are 0.001, 0.01, 0.1, 0.5, 1, 5, 10 and +Inf seconds, with
count and sum series. It records only
matched expected-EINVAL completions. `overdue_probes_total` counts each announced
probe once at an observed pending threshold crossing or a late completion,
including timed errors; missing-start dispatches are excluded. These aggregates
retain short stalls between scrapes even when the last-duration gauge is later
overwritten. They persist across helper recreation and reset with the observer
process, as ordinary Prometheus process counters do. A restart before a scrape
can lose measurements not yet collected. Only histogram `le` labels
are used; detailed bounded error reasons belong in logs.

State/metric output uses a fixed latest-frame handoff. Coalesced frames retain
observer-owned histogram/counters. A full stdout pipe drops bounded status
events without stopping local file output. A blocked filesystem writer can
leave both files stale while the observer/helper continue; it is never
replaced by an unlimited worker pool. Host scheduler or memory stalls can also
delay observation. There is no guaranteed alarm deadline during a global stall.

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
Clean observer shutdown removes only its own state/metrics after the writer
exits. A crash or stalled writer can leave stale output; consumers must enforce
freshness. Do not delete the lifetime lock or force a second probe during
recovery. Disabling the service changes no persistent schema or container
lifecycle, and oomd consumer policy remains separately controlled.
