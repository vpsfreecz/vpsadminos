{
  schemaVersion = 1;
  fixId = "network-backlog-unregister-serialization";
  oracles = [
    {
      id = "network-backlog-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/network-backlog-unregister-serialization.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/network-backlog-unregister-serialization.sh";
    }
  ];
}
