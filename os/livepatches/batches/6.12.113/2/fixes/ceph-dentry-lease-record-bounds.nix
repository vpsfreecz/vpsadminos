{
  id = "ceph-dentry-lease-record-bounds";
  patchIds = [ "ceph-dentry-lease-record-bounds" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "380bc69a0dbc50549cb196da40409aed69c84cfc";
    };
    status = "stable";
    upstream = "7286b2ffe04d4b39b4e9884f714792589d94f316";
    stable = "380bc69a0dbc50549cb196da40409aed69c84cfc";
  };
  cves = [ "CVE-2026-99307" ];
  prerequisites = [ ];
  functions = [
    {
      object = "ceph";
      symbol = "parse_reply_info_lease";
      sympos = 1;
    }
  ];
  oracleIds = [ ];
}
