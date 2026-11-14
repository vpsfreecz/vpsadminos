# Disposable RTNL watchdog test

Run `./test-runner.sh test rtnl-watchdog`. The test uses the pinned stable
6.12.117 kernel and development output, normally supplied by the binary cache.
Stop and investigate an unexpected full kernel build. One guest uses a sparse
tank disk and containers with cached static BusyBox; no distribution image is
fetched or built.

The test-only holder is copied unchanged from commit
`f554243ef9dca03bb9c60ee79e1226f8cb792757`,
`tests/suite/osctl-rtnl-monitor/{rtnl_fixture.c,Makefile}`. It has independent
release/status controls and a nine-second acquired-hold safety cap, and is
installed only by this test definition. There is no production BPF monitor
code or dependency.

## Watchdog and metrics

The startup gate and native cases use the installed watchdog, actual netlink
requests, schema 1 state and the generated runit service. They distinguish
pending dispatch from a helper observed inside sendmsg, check distress before
releasing RTNL, and verify matched completion, first-probe distress, inherited
lifetime-lock exclusion across observer death and supervisor retries, namespace
rejection and output backpressure. Killing an observer cannot cancel an
uninterruptible helper. The fixture never unlinks the lifetime lock.

The Rust helper uses duplex IPC on stdin (FD 0) and the inherited lifetime lock
on stdout (FD 1), which it never writes to. The fixture checks these descriptor
types and identities on the actual helper executable from the same package.

The normal node exporter runs only its textfile collector on guest loopback.
With oomd integration off, the test scrapes watchdog pending age, distress and
freshness during the held request. After release and a later fast response,
the completed-response histogram and overdue counter must retain the stall.
The guest runs no Prometheus server, and the watchdog opens no listener.

## Policy, actions and recovery

The policy cases use ordinary JSON Top with `--no-netif`, `--no-zfs`,
`--no-iostat` and `--no-processes`, real daemon commands and controlled
containers. The common
`top_schema: 1` metadata must report coherent current-run core data and explicit
nulls for disabled collectors. Each container has a 128 MiB cap, a resident
4 MiB variable retained by its init shell and a 100-percent CPU limit. Only the
disposable policy scenario shortens observations to one second. It explicitly sets ordinary thresholds to eight restart and
forty stop hits, with two fresh qualifying observations during watchdog distress.
Production defaults retain fifteen-second observations. Memory, CPU, ranking
and current-run checks still apply.

Request dispatch, daemon guard acceptance, payload EXIT and command completion
are separate observations. Shared kernel or NFS waits may delay both actions;
independent holder release allows bounded teardown. NFS cancellation and
stop/restart ordering are unchanged.

The dispatch case closes A's real action transport after daemon guard
acceptance. The production worker must retain its unknown slot and VPS
reservation while B reaches the guarded daemon path. An independent guarded
request must also show that A's manipulation lock is still held by
`ct_oomd_restart`. Guard acceptance and an unknown reservation do not themselves
prove remote completion. After holder
release, actual new runs and serialized old-run guard rejections establish
that completion. The unknown reservation must still persist through fresh
observations. Only then does the fixture terminate its isolated driver/sampler
process group. That teardown neither cancels a daemon command nor releases a
product slot automatically.

The public guarded CLI variants are tested separately. The production action
worker uses the existing client API to obtain a definitive daemon response.

## Timeout diagnostics

The Top/guard case writes `rtnl-watchdog-<id>.jsonl` phase records in the guest's
`/run/osvm/shared-dir`. Files with the same prefix use `.current.json` for the
latest phase and `.snapshot.jsonl` for one diagnostic snapshot scheduled after
90 seconds. The snapshot records known process identities and attempts a bounded
daemon thread listing. Missing or incomplete evidence remains unknown.

On failure, the example prints these files from the host side of the shared
mount and preserves the original error. Success still returns one JSON object.
Client failure or death does not establish daemon completion. Unknown command
effects suppress further container cleanup. If the Top/guard case was attempted
but incomplete, the later dispatch case fails before issuing a guest command.

These diagnostics preserve the existing deadlines and assertions. Use the phase
records to identify the blocked boundary before changing a deadline. A selected
suite run does not reproduce the broader CI scheduling context.

## Cost measurement

A warmed ten-second sample brackets the Rust observer/helper CPU counters with
monotonic time and reports clock-tick resolution, per-process RSS and observed
matched response records. RSS is sampled before and after; each process's VmHWM
is a lifetime high-water mark that includes startup. CPU deltas exclude startup
and the exporter, sampler, controller and daemon. Process utime plus stime includes kernel time
charged to the observer and helper; other system work is outside the sample.
This does not establish whole-node overhead or a general performance guarantee.

The existing one-container Top/guard case also runs two sequential warmed
ten-second windows at a one-second rate. Both disable iostat and process
collection. Network and ZFS collection use their defaults in the first window
and are disabled in the second. The output records each command, effective
collectors, sample count, sweep/window timestamps, snapshot duration and the
Top process's CPU/RSS with clock-tick resolution. Snapshot duration encloses
acquisition and projection, including enabled network/objset/ARC reads. The
CPU measurement window describes preceding coherent sample start to current
sample completion, not exact CPU-read instants. Iostat work is excluded from
both windows. The process CPU interval excludes daemon, exporter, controller
and other system work. These samples do not measure all default Top collection
or whole-node cost. A single pair does not establish a causal overhead ratio
or performance threshold.
