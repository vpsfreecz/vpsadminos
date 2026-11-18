{
  id = "ipv4-route-cwnd-zero";
  patchIds = [ "ipv4-reject-locked-zero-route-cwnd" ];
  provenance = {
    source = {
      repository = "vpsfreecz/linux";
      commit = "f62db2f88d7bd211a7eb95aae4ad55d89ff0d206";
    };
    status = "stable";
    upstream = "363c8c79220d0db4d65dcd570529ddda15067cb5";
    stable = "0a978359afe76aadfbc57acee88c08999543a7ae";
  };
  cves = [ "CVE-2026-99298" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "ip_fib_metrics_init";
      sympos = 0;
    }
  ];
  oracleIds = [ "ipv4-route-metrics-operation-safety" ];
}
