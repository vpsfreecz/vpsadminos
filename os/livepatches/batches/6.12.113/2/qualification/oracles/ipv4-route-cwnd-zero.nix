{
  schemaVersion = 1;
  fixId = "ipv4-route-cwnd-zero";
  oracles = [
    {
      id = "ipv4-route-metrics-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/ipv4-route-cwnd-zero.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/ipv4-route-cwnd-zero.sh";
    }
  ];
}
