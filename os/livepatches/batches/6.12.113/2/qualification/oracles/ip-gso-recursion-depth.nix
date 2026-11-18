{
  schemaVersion = 1;
  fixId = "ip-gso-recursion-depth";
  oracles = [
    {
      id = "ip-gso-tunnel-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/ip-gso-recursion-depth.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/ip-gso-recursion-depth.sh";
    }
  ];
}
