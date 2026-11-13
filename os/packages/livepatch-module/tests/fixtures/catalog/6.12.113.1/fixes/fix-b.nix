{
  id = "fix-b";
  patchIds = [
    "fix-b-change"
    "shared-prerequisite"
  ];
  provenance = {
    source = {
      repository = "vpsfreecz/linux";
      commit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    };
    status = "upstream";
    upstream = "cccccccccccccccccccccccccccccccccccccccc";
  };
  cves = [ "CVE-2099-0001" ];
  prerequisites = [ "fix-a" ];
  functions = [
    {
      object = "vmlinux";
      symbol = "function_b";
      sympos = 0;
    }
  ];
  oracleIds = [ "oracle-b" ];
}
