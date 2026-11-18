{
  schemaVersion = 1;
  fixId = "ceph-snap-trace-count-bounds";
  oracles = [
    {
      id = "ceph-snapshot-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/ceph-operation-safety.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/ceph-snap-trace-count-bounds.sh";
    }
  ];
}
