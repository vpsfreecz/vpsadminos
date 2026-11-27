{
  schemaVersion = 1;
  fixId = "nfsd-sequence-reply-preflight";
  oracles = [
    {
      id = "nfsd-sequence-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [ "amd" ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.48/1/qualification/helpers/nfsd-sequence-reply-preflight.nix";
      validator = "os/livepatches/batches/6.12.48/1/qualification/validators/nfsd-sequence-reply-preflight.sh";
    }
  ];
}
