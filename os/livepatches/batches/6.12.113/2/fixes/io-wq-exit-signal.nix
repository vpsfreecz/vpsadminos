{
  id = "io-wq-exit-signal";
  patchIds = [ "io-wq-preserve-exit-signal" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "62996803c1b5f18176de255db4c843021f2d19c8";
    };
    status = "stable";
    upstream = "63c103279a95e82280092f2f4232e91e8117a252";
    stable = "62996803c1b5f18176de255db4c843021f2d19c8";
  };
  cves = [ "CVE-2026-99228" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "io_worker_handle_work";
      sympos = 1;
    }
  ];
  oracleIds = [ ];
}
