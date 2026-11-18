{
  schemaVersion = 1;
  fixId = "skb-zerocopy-shared-frag";
  oracles = [
    {
      id = "nfqueue-xfrm-operation-safety";
      scope = "fix";
      role = "operation-safety";
      applicablePlatforms = [
        "amd"
        "intel"
      ];
      timeoutClass = "oracle";
      expectedOutcome = "success";
      testAdapter = "os/livepatches/batches/6.12.113/2/qualification/helpers/skb-zerocopy-shared-frag.nix";
      validator = "os/livepatches/batches/6.12.113/2/qualification/validators/skb-zerocopy-shared-frag.sh";
    }
  ];
}
