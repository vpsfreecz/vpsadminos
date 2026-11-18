{
  schemaVersion = 1;
  fixId = "pivot-root-mount-parent-lifetime";
  oracles = [
    {
      id = "pivot-root-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/pivot-root-mount-parent-lifetime.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/pivot-root-mount-parent-lifetime.sh";
    }
  ];
}
