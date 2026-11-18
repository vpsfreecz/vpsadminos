{
  schemaVersion = 1;
  fixId = "bpf-atomic-fetch-precision";
  oracles = [
    {
      id = "bpf-atomic-fetch-precision-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/bpf-atomic-fetch-precision.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/bpf-atomic-fetch-precision.sh";
    }
  ];
}
