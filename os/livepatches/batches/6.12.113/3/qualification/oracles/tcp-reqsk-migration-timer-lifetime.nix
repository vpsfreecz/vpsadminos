{
  schemaVersion = 1;
  fixId = "tcp-reqsk-migration-timer-lifetime";
  oracles = [
    {
      id = "tcp-reqsk-migration-timer-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/3/qualification/helpers/tcp-reqsk-migration-timer-lifetime.nix";
      validator = "os/livepatches/batches/6.12.113/3/qualification/validators/tcp-reqsk-migration-timer-lifetime.sh";
    }
  ];
}
