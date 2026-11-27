{
  id = "ceph-mdsmap-rank-bounds";
  patchIds = [ "ceph-mdsmap-rank-bounds" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "7931e6798f419bda9ac8cf0c095323eff90a7f52";
    };
    status = "stable";
    upstream = "c1742590d2b2fc5fb217e1a9b520108f1fe282e5";
    stable = "7931e6798f419bda9ac8cf0c095323eff90a7f52";
  };
  cves = [ "CVE-2026-99306" ];
  prerequisites = [ ];
  functions = [
    {
      object = "ceph";
      symbol = "ceph_mdsmap_decode";
      sympos = 0;
    }
  ];
  oracleIds = [ ];
}
