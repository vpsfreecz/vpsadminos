{
  schemaVersion = 1;
  fixId = "io-waitid-request-ownership";
  oracles = [
    {
      id = "io-waitid-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/io-waitid-request-ownership.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/io-waitid-request-ownership.sh";
    }
  ];
}
