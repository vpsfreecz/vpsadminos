{
  schemaVersion = 1;
  fixId = "bpf-callback-frame-precision";
  oracles = [
    {
      id = "bpf-callback-frame-precision-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/bpf-callback-frame-precision.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/bpf-callback-frame-precision.sh";
    }
  ];
}
