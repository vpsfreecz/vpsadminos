{
  id = "nfsd-openowner-list-locking";
  patchIds = [ "nfsd-openowner-list-locking" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "202b7a6c462daa55a9f4b01f0a25eca2b8d5f2e3";
    };
    status = "stable";
    upstream = "5336899b5491eaa2ac22c2925d87daab2b140eb3";
    stable = "202b7a6c462daa55a9f4b01f0a25eca2b8d5f2e3";
  };
  cves = [ "CVE-2026-99310" ];
  prerequisites = [ ];
  functions = [
    {
      object = "nfsd";
      symbol = "client_has_state";
      sympos = 1;
    }
  ];
  oracleIds = [ "nfsd-openowner-operation-safety" ];
}
