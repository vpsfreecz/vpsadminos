{
  schemaVersion = 1;
  fixId = "io-wq-exit-signal";
  oracles = [
    {
      id = "io-wq-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/io-wq-exit-signal.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/io-wq-exit-signal.sh";
    }
  ];
}
