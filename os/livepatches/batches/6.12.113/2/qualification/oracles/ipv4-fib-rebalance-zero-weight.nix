{
  schemaVersion = 1;
  fixId = "ipv4-fib-rebalance-zero-weight";
  oracles = [
    {
      id = "ipv4-fib-rebalance-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/ipv4-fib-rebalance-zero-weight.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/ipv4-fib-rebalance-zero-weight.sh";
    }
  ];
}
