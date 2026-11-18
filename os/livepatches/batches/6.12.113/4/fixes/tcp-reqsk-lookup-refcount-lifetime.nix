{
  id = "tcp-reqsk-lookup-refcount-lifetime";
  patchIds = [ "tcp-reject-unhashed-reqsk-after-reference" ];
  provenance = {
    source = {
      repository = "vpsfreecz/linux";
      commit = "564f9982a87625e006b8465bdb4a7deb51cf55e0";
    };
    status = "stable";
    upstream = "4e2b3ef19e0e04adca38442f07dd6bc93c712bf1";
    stable = "d69100340b4cae08d40f898f1b601032403f6be6";
  };
  cves = [ "CVE-2026-99288" ];
  prerequisites = [
    "tcp-reqsk-migration-timer-lifetime"
    "tcp-reqsk-refcount-cleanup-preparation"
  ];
  functions = [
    {
      object = "vmlinux";
      symbol = "__inet6_lookup_established";
      sympos = 0;
    }
    {
      object = "vmlinux";
      symbol = "__inet_lookup_established";
      sympos = 0;
    }
  ];
  oracleIds = [ "tcp-reqsk-lookup-lifetime-operation-safety" ];
}
