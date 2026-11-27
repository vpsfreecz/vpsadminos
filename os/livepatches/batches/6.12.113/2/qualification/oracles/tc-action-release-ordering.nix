{
  schemaVersion = 1;
  fixId = "tc-action-release-ordering";
  oracles = [
    {
      id = "tc-action-lifecycle-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/tc-action-release-ordering.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/tc-action-release-ordering.sh";
    }
  ];
}
