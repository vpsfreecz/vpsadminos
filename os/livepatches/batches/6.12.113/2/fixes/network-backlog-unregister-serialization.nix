{
  id = "network-backlog-unregister-serialization";
  patchIds = [ "net-serialize-backlog-enqueue-on-unregister" ];
  provenance = {
    source = {
      repository = "vpsfreecz/linux";
      commit = "ec9793c2279c5210a8f2d0191ef34c3891ac4e2b";
    };
    status = "stable";
    upstream = "46762cefe7f4e5bffc1eb467810a7bbb02e461d7";
    stable = "cbe10ea090ea9d6fa5ff50c9b44f2a86fe56f0b7";
  };
  cves = [ "CVE-2026-72493" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "enqueue_to_backlog";
      sympos = 1;
    }
  ];
  oracleIds = [ ];
}
