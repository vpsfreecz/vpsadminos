{ kernelVersion }:
{
  # The ZFS paired with 6.18.49 refuses a promoted-clone replication cycle.
  # The stable ZFS source does not guarantee that behavior; keep the refusal
  # check with the pair that implements it and retire it with that pair.
  runnerTests = [ "zfs/rsend-promoted-cycle-${kernelVersion}" ];
}
