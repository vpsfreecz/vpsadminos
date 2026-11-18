{
  id = "io-cq-overflow-wait-progress";
  patchIds = [ "io-uring-wait-stop-stuck-overflow-spin" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "a6cfc85c6bf9498aaf1978b503f9663635a1aa22";
    };
    status = "stable";
    upstream = "34f5a664c34d3cb62f6bec7f4156754594a7d25b";
    stable = "a6cfc85c6bf9498aaf1978b503f9663635a1aa22";
  };
  cves = [ "CVE-2026-99229" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "io_cqring_wait";
      sympos = 1;
    }
  ];
  oracleIds = [ "io-cq-wait-operation-safety" ];
}
