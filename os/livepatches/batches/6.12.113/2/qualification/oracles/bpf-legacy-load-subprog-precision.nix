{
  schemaVersion = 1;
  fixId = "bpf-legacy-load-subprog-precision";
  oracles = [
    {
      id = "bpf-legacy-load-subprog-precision-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/bpf-legacy-load-subprog-precision.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/bpf-legacy-load-subprog-precision.sh";
    }
  ];
}
