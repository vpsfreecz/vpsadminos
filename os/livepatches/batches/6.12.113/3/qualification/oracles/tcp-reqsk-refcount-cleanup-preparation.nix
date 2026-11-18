{
  schemaVersion = 1;
  fixId = "tcp-reqsk-refcount-cleanup-preparation";
  oracles = [
    {
      id = "tcp-reqsk-refcount-cleanup-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/3/qualification/helpers/tcp-reqsk-refcount-cleanup-preparation.nix";
      validator = "os/livepatches/batches/6.12.113/3/qualification/validators/tcp-reqsk-refcount-cleanup-preparation.sh";
    }
  ];
}
