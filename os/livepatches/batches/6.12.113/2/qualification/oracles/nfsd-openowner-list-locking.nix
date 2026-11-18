{
  schemaVersion = 1;
  fixId = "nfsd-openowner-list-locking";
  oracles = [
    {
      id = "nfsd-openowner-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/nfsd-openowner-operation-safety.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/nfsd-openowner-list-locking.sh";
    }
  ];
}
