{
  id = "tcp-reqsk-migration-timer-lifetime";
  patchIds = [ "tcp-stop-failed-migrated-reqsk-timer" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "f7fba81b00699360f96ed7d9a47b8c801e74c6f9";
    };
    status = "stable";
    upstream = "97c8a3c1f73d828de43a5a88e8a9a143efb2b661";
    stable = "f7fba81b00699360f96ed7d9a47b8c801e74c6f9";
  };
  cves = [ "CVE-2026-99270" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "reqsk_timer_handler";
      sympos = 1;
    }
  ];
  oracleIds = [ "tcp-reqsk-migration-timer-operation-safety" ];
}
