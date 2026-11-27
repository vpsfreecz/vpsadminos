{ kernelVersion }:
{
  # The ZFS paired with 6.18.49 refuses a promoted-clone replication cycle.
  # The stable ZFS source does not guarantee that behavior; keep the refusal
  # check with the pair that implements it and retire it with that pair.
  runnerTests = [
    "kernel/cpu-view/cgroups-v1"
    "kernel/cpu-view/cgroups-v2"
    "kernel/loadavg"
    "kernel/memory-view/cgroups-v1"
    "kernel/memory-view/cgroups-v2"
    "kernel/namespaces"
    "kernel/tracing-tools"
    "osctl/ct-chown-filecaps-zfs-${kernelVersion}"
    "osctl/ct-exec-v1"
    "osctl/ct-exec-v2"
    "osctld/direct-start"
    "systemd/ebpf"
    "zfs/large-folios"
    "zfs/rsend-promoted-cycle-${kernelVersion}"
    "zfs/ugidmap"
  ];
}
