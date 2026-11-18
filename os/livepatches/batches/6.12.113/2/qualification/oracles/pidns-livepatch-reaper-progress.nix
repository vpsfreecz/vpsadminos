{
  schemaVersion = 1;
  fixId = "pidns-livepatch-reaper-progress";
  oracles = [
    {
      id = "pidns-livepatch-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/pidns-livepatch-reaper-progress.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/pidns-livepatch-reaper-progress.sh";
    }
  ];
}
