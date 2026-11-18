{
  id = "request-key-auth-payload-lifetime";
  patchIds = [ "keys-check-auth-payload-in-process-search" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "984a178d54515779a1bee100b92a6cee8777c830";
    };
    status = "stable";
    upstream = "0a0ec45bf577a9b4d4960567f20d3877ef480de9";
    stable = "984a178d54515779a1bee100b92a6cee8777c830";
  };
  cves = [ "CVE-2026-99225" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "search_process_keyrings_rcu";
      sympos = 0;
    }
  ];
  oracleIds = [ "request-key-operation-safety" ];
}
