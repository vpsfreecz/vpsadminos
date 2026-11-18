{
  schemaVersion = 1;
  fixId = "ipv6-multicast-unresolved-dst-lifetime";
  oracles = [
    {
      id = "ipv6-multicast-routing-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/ipv6-multicast-unresolved-dst-lifetime.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/ipv6-multicast-unresolved-dst-lifetime.sh";
    }
  ];
}
