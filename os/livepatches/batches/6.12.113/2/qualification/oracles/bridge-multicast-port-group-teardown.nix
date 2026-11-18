{
  schemaVersion = 1;
  fixId = "bridge-multicast-port-group-teardown";
  oracles = [
    {
      id = "bridge-multicast-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/bridge-multicast-port-group-teardown.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/bridge-multicast-port-group-teardown.sh";
    }
  ];
}
