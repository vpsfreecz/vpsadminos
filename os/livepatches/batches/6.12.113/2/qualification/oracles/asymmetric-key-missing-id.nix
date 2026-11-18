{
  schemaVersion = 1;
  fixId = "asymmetric-key-missing-id";
  oracles = [
    {
      id = "asymmetric-key-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/asymmetric-key-missing-id.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/asymmetric-key-missing-id.sh";
    }
  ];
}
