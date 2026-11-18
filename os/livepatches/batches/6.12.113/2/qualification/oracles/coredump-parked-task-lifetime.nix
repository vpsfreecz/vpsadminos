{
  schemaVersion = 1;
  fixId = "coredump-parked-task-lifetime";
  oracles = [
    {
      id = "coredump-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/coredump-parked-task-lifetime.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/coredump-parked-task-lifetime.sh";
    }
  ];
}
