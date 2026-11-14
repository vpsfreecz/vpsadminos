# Disposable RTNL watchdog test

Run `./test-runner.sh test rtnl-watchdog`. The test uses the pinned stable
6.12.117 kernel and development output, normally supplied by the binary cache.
Stop and investigate an unexpected full kernel build. One guest uses a sparse
tank disk. No distribution image is fetched or built.

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
The test scrapes watchdog pending age, distress and
freshness during the held request. After release and a later fast response,
the completed-response histogram and overdue counter must retain the stall.
The guest runs no Prometheus server, and the watchdog opens no listener.

## Cost measurement

A warmed ten-second sample brackets the Rust observer/helper CPU counters with
monotonic time and reports clock-tick resolution, per-process RSS and observed
matched response records. RSS is sampled before and after; each process's VmHWM
is a lifetime high-water mark that includes startup. CPU deltas exclude startup
and the exporter, sampler, controller and daemon. Process utime plus stime includes kernel time
charged to the observer and helper; other system work is outside the sample.
This does not establish whole-node overhead or a general performance guarantee.
