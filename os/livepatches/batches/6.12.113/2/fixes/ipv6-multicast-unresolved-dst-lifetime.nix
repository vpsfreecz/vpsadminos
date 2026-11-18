{
  id = "ipv6-multicast-unresolved-dst-lifetime";
  patchIds = [ "ipv6-drop-dst-before-multicast-resolution" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "42ef371466d5648f5c9e8bc219f0af0a2c2bbf8c";
    };
    status = "stable";
    upstream = "235b42b5860189eb8c27c36435ad932cae65a734";
    stable = "42ef371466d5648f5c9e8bc219f0af0a2c2bbf8c";
  };
  cves = [ "CVE-2026-90111" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "ip6mr_cache_report";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "ip6mr_cache_unresolved";
      sympos = 1;
    }
  ];
  oracleIds = [ "ipv6-multicast-routing-operation-safety" ];
}
