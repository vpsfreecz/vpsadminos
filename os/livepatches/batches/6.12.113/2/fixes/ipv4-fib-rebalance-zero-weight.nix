{
  id = "ipv4-fib-rebalance-zero-weight";
  patchIds = [ "ipv4-guard-zero-weight-fib-rebalance" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "0800c92ca5d1983df6843a5435299978901d1d02";
    };
    status = "stable";
    upstream = "5046d2880fec7d49ebed2fd2866747ee1d06ad71";
    stable = "0800c92ca5d1983df6843a5435299978901d1d02";
  };
  cves = [ "CVE-2026-99121" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "fib_rebalance";
      sympos = 1;
    }
  ];
  oracleIds = [ "ipv4-fib-rebalance-operation-safety" ];
}
