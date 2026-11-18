{
  schemaVersion = 1;
  fixId = "bpf-null-call-argument-precision";
  oracles = [
    {
      id = "bpf-null-call-argument-precision-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/bpf-null-call-argument-precision.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/bpf-null-call-argument-precision.sh";
    }
  ];
}
