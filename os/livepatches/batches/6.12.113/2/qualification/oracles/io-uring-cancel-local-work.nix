{
  schemaVersion = 1;
  fixId = "io-uring-cancel-local-work";
  oracles = [
    {
      id = "io-uring-cancel-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/io-uring-cancel-local-work.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/io-uring-cancel-local-work.sh";
    }
  ];
}
