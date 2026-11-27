{
  id = "ip-gso-recursion-depth";
  patchIds = [ "net-limit-ip-gso-recursion" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "cadffc83ee1a560d5cd18e6d607c1d76f6fd4bd4";
    };
    status = "stable";
    upstream = "006c8b834aed8b02bd8fb9fb05e9e7ead37d1763";
    stable = "cadffc83ee1a560d5cd18e6d607c1d76f6fd4bd4";
  };
  cves = [ "CVE-2026-98853" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "__skb_gso_segment";
      sympos = 0;
    }
    {
      object = "vmlinux";
      symbol = "inet_gso_segment";
      sympos = 0;
    }
    {
      object = "vmlinux";
      symbol = "ipv6_gso_segment";
      sympos = 1;
    }
  ];
  oracleIds = [ "ip-gso-tunnel-operation-safety" ];
}
