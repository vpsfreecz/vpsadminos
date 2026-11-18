{
  schemaVersion = 1;
  fixId = "propagated-mount-busy-unmount";
  oracles = [
    {
      id = "mount-propagation-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/propagated-mount-busy-unmount.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/propagated-mount-busy-unmount.sh";
    }
  ];
}
