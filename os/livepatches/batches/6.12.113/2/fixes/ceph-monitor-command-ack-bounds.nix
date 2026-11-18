{
  id = "ceph-monitor-command-ack-bounds";
  patchIds = [ "ceph-monitor-command-ack-bounds" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "c6696ac94c8c3ad79a9fa57fc334af2dc1a1f72e";
    };
    status = "stable";
    upstream = "62b41a16d8603d4d809fda212f15c3e9c783a82b";
    stable = "c6696ac94c8c3ad79a9fa57fc334af2dc1a1f72e";
  };
  cves = [ "CVE-2026-99296" ];
  prerequisites = [ ];
  functions = [
    {
      object = "libceph";
      symbol = "mon_dispatch";
      sympos = 1;
    }
  ];
  oracleIds = [ "ceph-monitor-command-operation-safety" ];
}
