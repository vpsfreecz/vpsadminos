{
  schemaVersion = 1;
  fixId = "sctp-address-work-teardown";
  oracles = [
    {
      id = "sctp-address-work-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/sctp-address-work-teardown.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/sctp-address-work-teardown.sh";
    }
  ];
}
