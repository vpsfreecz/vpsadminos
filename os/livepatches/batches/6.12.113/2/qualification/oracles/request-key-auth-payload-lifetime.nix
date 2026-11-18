{
  schemaVersion = 1;
  fixId = "request-key-auth-payload-lifetime";
  oracles = [
    {
      id = "request-key-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/request-key-auth-payload-lifetime.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/request-key-auth-payload-lifetime.sh";
    }
  ];
}
