{
  schemaVersion = 1;
  fixId = "cephx-decrypt-header-bounds";
  oracles = [
    {
      id = "cephx-auth-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/ceph-operation-safety.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/cephx-decrypt-header-bounds.sh";
    }
  ];
}
