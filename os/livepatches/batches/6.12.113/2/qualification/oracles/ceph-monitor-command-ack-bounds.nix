{
  schemaVersion = 1;
  fixId = "ceph-monitor-command-ack-bounds";
  oracles = [
    {
      id = "ceph-monitor-command-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/ceph-operation-safety.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/ceph-monitor-command-ack-bounds.sh";
    }
  ];
}
