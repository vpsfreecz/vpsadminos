{
  id = "sctp-address-work-teardown";
  patchIds = [ "sctp-shutdown-address-work-timer" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "d49eff15261dd62e4fa3a316c26cb1f537a60464";
    };
    status = "stable";
    upstream = "976c19de0f22a857ba0112f39635f8fd7a257568";
    stable = "d49eff15261dd62e4fa3a316c26cb1f537a60464";
  };
  cves = [ "CVE-2026-72383" ];
  prerequisites = [ ];
  functions = [
    {
      object = "sctp";
      symbol = "sctp_defaults_exit";
      sympos = 1;
    }
  ];
  oracleIds = [ "sctp-address-work-operation-safety" ];
}
