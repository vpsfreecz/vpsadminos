# Disposable RTNL monitor test

`./test-runner.sh test osctl-rtnl-monitor` runs the production monitor against
the stable 6.12.117 VM kernel with cgroup v2. Its matching kernel image and
development output should be substituted from the normal vpsAdminOS cache.
An unexpected kernel compilation needs investigation before proceeding.

One startup smoke test uses the generated inventory and monitor runit services,
the real osctld client, and one container with a small static BusyBox init. It
creates that container through `--skip-image`, so no distribution image is
downloaded or built. The BusyBox package must also be substitutable. The smoke
checks the exported container root/init identity, inventory heartbeat and stable
run token, valid snapshots, advancing metrics and output removal on stop. Both
services and the container stop before the isolated cases below. The same VM
uses the normal `with-tank` helper and one sparse test disk.

The test-only module exposes root-only proc controls. `call` performs the
requested RTNL wrapper in the writing task, preserving its cgroup identity.
`release` and `status` never acquire RTNL. Acquired holds expire in the kernel
after at most nine seconds even if the test controller fails. Module references
prevent removal during a call, and ordinary teardown releases callers before
unloading. This module is installed only by this test definition.

The fixture registers three synthetic container-root cgroups, each containing
nested groups, through the production roots-file schema. It checks pending calls
before releasing the holder, return and interruption cleanup, mapping changes,
staleness, limits, attach failure and optional diagnostic backpressure. The
monitor deliberately reports acquisition-call age, which includes preemption;
the CPU-only control does not establish sleeping time or lock ownership.

The overhead example prints one paired off/on measurement for idle, networking,
uncontended acquisition calls and CPU load in the same guest. These controls use
100 ms frames with stacks disabled. Rows contain elapsed workload time,
cumulative process CPU time since startup, memory, visible BPF map sizes,
output size, frame gaps and loss state. CPU totals cover startup and collection
as well as the workload. The paired timings include scheduling noise and do
not establish general performance guarantees.

A separate ten-second idle sample uses the default one-second frame and wait
intervals, entry-stack sampling and three roots. It warms up on valid frames,
then brackets the sample with lightweight process CPU counters and monotonic
timestamps. It reports the CPU delta, elapsed time and clock-tick resolution;
heavy map inspection runs afterward. This measures native process CPU use.
CPU charged to callers during BPF execution, the inventory adapter and other
node services falls outside that sample. RSS and map figures describe the
native process and directly held map FDs; live inner maps and other kernel
allocations require separate accounting.

The VM reuses one exact host PID through `ns_last_pid` after a killed waiter,
then checks its new root attribution. An unrelated guest fork racing that
witness fails explicitly. Core unit tests cover injected map/worker races;
the VM also checks short-lived task exits and root/run replacement.
