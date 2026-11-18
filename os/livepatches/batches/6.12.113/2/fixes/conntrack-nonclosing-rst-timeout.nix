{
  id = "conntrack-nonclosing-rst-timeout";
  patchIds = [ "conntrack-use-unack-timeout-for-nonclosing-rst" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "4d39a039d0b7737f8475c2431f18572b3b186a3b";
    };
    status = "stable";
    upstream = "bf80e6802273a900311b44e47c9b1a59c6d2473c";
    stable = "4d39a039d0b7737f8475c2431f18572b3b186a3b";
  };
  cves = [ "CVE-2026-99283" ];
  prerequisites = [ ];
  functions = [
    {
      object = "nf_conntrack";
      symbol = "nf_conntrack_tcp_packet";
      sympos = 0;
    }
  ];
  oracleIds = [ "conntrack-tcp-operation-safety" ];
}
