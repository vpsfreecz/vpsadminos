{
  id = "fix-a";
  patchIds = [ "shared-prerequisite" ];
  provenance = {
    source = {
      repository = "vpsfreecz/linux";
      commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    };
    status = "downstream-only";
    upstream = null;
    stable = null;
  };
  cves = [ ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "function_a";
      sympos = 0;
    }
  ];
  oracleIds = [ "oracle-a" ];
}
