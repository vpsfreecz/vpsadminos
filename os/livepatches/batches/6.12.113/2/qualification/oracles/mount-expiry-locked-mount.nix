{
  schemaVersion = 1;
  fixId = "mount-expiry-locked-mount";
  oracles = [
    {
      id = "mount-expiry-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/mount-expiry-locked-mount.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/mount-expiry-locked-mount.sh";
    }
  ];
}
