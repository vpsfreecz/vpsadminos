{
  id = "ceph-snap-trace-count-bounds";
  patchIds = [ "ceph-snap-trace-count-bounds" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "bf8f13872959af1d87e36b7d27096a09fdcf6e47";
    };
    status = "stable";
    upstream = "b3bf89767e3ca9506f1c7167cac97c41ec254d42";
    stable = "bf8f13872959af1d87e36b7d27096a09fdcf6e47";
  };
  cves = [ "CVE-2026-99304" ];
  prerequisites = [ ];
  functions = [
    {
      object = "ceph";
      symbol = "ceph_update_snap_trace";
      sympos = 0;
    }
  ];
  oracleIds = [ ];
}
