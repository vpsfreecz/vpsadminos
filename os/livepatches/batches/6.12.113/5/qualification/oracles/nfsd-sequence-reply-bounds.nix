{
  schemaVersion = 1;
  fixId = "nfsd-sequence-reply-bounds";
  oracles = [
    {
      id = "nfsd-sequence-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/5/qualification/helpers/nfsd-sequence-operation-safety.nix";
      validator = "os/livepatches/batches/6.12.113/5/qualification/validators/nfsd-sequence-reply-bounds.sh";
    }
  ];
}
