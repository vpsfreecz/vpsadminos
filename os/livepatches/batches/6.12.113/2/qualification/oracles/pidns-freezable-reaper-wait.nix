{
  schemaVersion = 1;
  fixId = "pidns-freezable-reaper-wait";
  oracles = [
    {
      id = "pidns-freezable-reaper-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/pidns-freezable-reaper-wait.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/pidns-freezable-reaper-wait.sh";
    }
  ];
}
