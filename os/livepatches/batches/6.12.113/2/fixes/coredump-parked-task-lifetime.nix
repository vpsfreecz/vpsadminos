{
  id = "coredump-parked-task-lifetime";
  patchIds = [ "coredump-hold-rcu-releasing-parked-threads" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "0fce73efee40c65ce26641c5d93942462f9e8307";
    };
    status = "stable";
    upstream = "61d58591aa0188bf2463e263962256316ff8b576";
    stable = "0fce73efee40c65ce26641c5d93942462f9e8307";
  };
  cves = [ "CVE-2026-99218" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "do_coredump";
      sympos = 0;
    }
  ];
  oracleIds = [ "coredump-operation-safety" ];
}
