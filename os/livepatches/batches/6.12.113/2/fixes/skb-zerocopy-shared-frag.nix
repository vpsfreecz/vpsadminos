{
  id = "skb-zerocopy-shared-frag";
  patchIds = [ "skb-propagate-shared-frag-on-zerocopy" ];
  provenance = {
    source = {
      repository = "vpsfreecz/linux";
      commit = "5c8e1987e80cff7ca6187c59d538a03802819334";
    };
    status = "stable";
    upstream = "79dc34beb1fdb3da79753e51e15c68591a2561fe";
    stable = "fe8477e23dd2ee6bce231d65f2586a333b211dc0";
  };
  cves = [ "CVE-2026-99284" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "skb_zerocopy";
      sympos = 0;
    }
  ];
  oracleIds = [ ];
}
