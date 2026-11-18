{
  schemaVersion = 1;
  fixId = "io-cq-overflow-wait-progress";
  oracles = [
    {
      id = "io-cq-wait-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/io-cq-overflow-wait-progress.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/io-cq-overflow-wait-progress.sh";
    }
  ];
}
