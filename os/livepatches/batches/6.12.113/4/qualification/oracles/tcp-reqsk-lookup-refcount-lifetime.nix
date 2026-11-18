{
  schemaVersion = 1;
  fixId = "tcp-reqsk-lookup-refcount-lifetime";
  oracles = [
    {
      id = "tcp-reqsk-lookup-lifetime-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/4/qualification/helpers/tcp-reqsk-lookup-refcount-lifetime.nix";
      validator = "os/livepatches/batches/6.12.113/4/qualification/validators/tcp-reqsk-lookup-refcount-lifetime.sh";
    }
  ];
}
