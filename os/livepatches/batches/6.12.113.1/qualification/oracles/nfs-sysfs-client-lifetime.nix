{
  schemaVersion = 1;
  fixId = "nfs-sysfs-client-lifetime";
  oracles = [
    {
      id = "nfs-client-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113.1/qualification/helpers/nfs-sysfs-client-lifetime.nix";
      validator = "os/livepatches/batches/6.12.113.1/qualification/validators/nfs-sysfs-client-lifetime.sh";
    }
  ];
}
