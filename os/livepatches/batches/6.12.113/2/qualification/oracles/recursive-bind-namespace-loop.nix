{
  schemaVersion = 1;
  fixId = "recursive-bind-namespace-loop";
  oracles = [
    {
      id = "recursive-bind-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/recursive-bind-namespace-loop.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/recursive-bind-namespace-loop.sh";
    }
  ];
}
