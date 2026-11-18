{
  id = "conntrack-nonclosing-rst-timeout";
  patchIds = [
    "conntrack-use-unack-timeout-for-nonclosing-rst"
    "conntrack-bound-unack-timeout-by-established"
  ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "ea9137859d913a21aab5a3fe06414890159793a7";
    };
    status = "stable";
    upstream = "73df81b38cb7f70a347a97370386378a86e53019";
    stable = "ea9137859d913a21aab5a3fe06414890159793a7";
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
