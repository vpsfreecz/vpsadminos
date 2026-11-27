{
  schemaVersion = 1;
  fixId = "conntrack-nonclosing-rst-timeout";
  oracles = [
    {
      id = "conntrack-tcp-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/conntrack-nonclosing-rst-timeout.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/conntrack-nonclosing-rst-timeout.sh";
    }
  ];
}
