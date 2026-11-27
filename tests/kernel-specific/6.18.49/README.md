# Tests owned by Linux 6.18.49

These registrations import their shared test sources and run them with Linux
6.18.49. They keep version-specific contracts out of the shared suite without
weakening the assertions:

- the CPU-view tests require `/proc/cpuinfo` to stop at the host's possible CPU
  limit when a cgroup requests more CPUs than the host provides;
- the load-average and memory-view tests require the newer per-cgroup sysinfo,
  memory and swap ABIs;
- the namespace and direct-start tests require container init to have a
  dedicated syslog namespace, distinct from the host, and require `osctl ct
  exec` and, where checked, attach to remain in that container namespace;
- tracing, container execution and systemd eBPF require the tracing namespace,
  container BPF policy and kernfs visibility helper provided by this kernel;
- large-folio, UID/GID mapping and ZFS file-capability tests require the Linux
  and OpenZFS pair selected for this release; and
- the promoted-clone send test requires that pair to reject cyclic parent and
  clone origin dependencies.

Run an entry with `./test-runner.sh test TEST-ID` from the repository root. The
promoted-clone test runs only `rsend_008_pos`, with a five-minute limit on the
test body. A hang, unexpected success, unrelated failure or skip does not pass.

When the normal stable kernel changes, migrate or retire each registration
after checking its source contract. Do not move these assumptions to a new
kernel or OpenZFS pair automatically.
