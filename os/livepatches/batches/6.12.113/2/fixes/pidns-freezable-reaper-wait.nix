{
  id = "pidns-freezable-reaper-wait";
  patchIds = [ "pidns-make-reaper-waits-freezable" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "4b47107f1a80c809c80093e872bcaccdbae13db4";
    };
    status = "stable";
    upstream = "81933038f5e273d17ed22792f906889393b204c5";
    stable = "4b47107f1a80c809c80093e872bcaccdbae13db4";
  };
  cves = [ "CVE-2026-99249" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "do_wait";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "zap_pid_ns_processes";
      sympos = 0;
    }
  ];
  oracleIds = [ "pidns-freezable-reaper-operation-safety" ];
}
