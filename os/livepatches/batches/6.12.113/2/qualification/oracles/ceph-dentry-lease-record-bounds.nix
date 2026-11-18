{
  schemaVersion = 1;
  fixId = "ceph-dentry-lease-record-bounds";
  oracles = [
    {
      id = "ceph-dentry-lease-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/ceph-operation-safety.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/ceph-dentry-lease-record-bounds.sh";
    }
  ];
}
