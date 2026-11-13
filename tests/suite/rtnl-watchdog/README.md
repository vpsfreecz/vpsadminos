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

The normal node exporter runs only its textfile collector on guest loopback.
With oomd integration off, the test scrapes watchdog pending age, distress and
freshness during the held request. After release and a later fast response,
the completed-response histogram and overdue counter must retain the stall.
The guest runs no Prometheus server, and the watchdog opens no listener.

## Policy, actions and recovery

The policy cases use the installed lean sampler, real daemon commands and
controlled containers. Only the disposable policy scenario shortens observations
to one second. It explicitly sets ordinary thresholds to eight restart and
forty stop hits, with two fresh qualifying observations during watchdog distress.
Production defaults retain fifteen-second observations. Memory, CPU, ranking
and current-run checks still apply.

Request dispatch, daemon guard acceptance, payload EXIT and command completion
are separate observations. Shared kernel or NFS waits may delay both actions;
independent holder release allows bounded teardown. NFS cancellation and
stop/restart ordering are unchanged.

The dispatch case closes A's real action transport after daemon guard
acceptance. The production worker must retain its unknown slot and VPS
reservation while B reaches the guarded daemon path. Guard acceptance and an
unknown reservation do not themselves prove remote completion. After holder
release, actual new runs and serialized old-run guard rejections establish
that completion. The unknown reservation must still persist through fresh
observations. Only then does the fixture terminate its isolated driver/sampler
process group. That teardown neither cancels a daemon command nor releases a
product slot automatically.

The public guarded CLI variants are tested separately. The production action
worker uses the existing client API to obtain a definitive daemon response.

## Cost measurement

A warmed ten-second sample brackets observer/helper CPU counters with monotonic
time and reports clock-tick resolution. It excludes startup and the exporter,
sampler, controller and daemon. Process utime plus stime includes kernel time
charged to the observer and helper; other system work is outside the sample.
This does not establish whole-node overhead or a general performance guarantee.
