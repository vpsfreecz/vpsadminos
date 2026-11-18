{
  id = "tc-action-release-ordering";
  patchIds = [ "tc-serialize-action-release-counters" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "969ad6f2b266f383b44194d50d15631969b26222";
    };
    status = "stable";
    upstream = "7b16eb911091aae237a8673da94e4dfb9cd21d54";
    stable = "969ad6f2b266f383b44194d50d15631969b26222";
  };
  cves = [ "CVE-2026-99167" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "__tcf_action_put";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "tcf_idrinfo_destroy";
      sympos = 0;
    }
  ];
  oracleIds = [ "tc-action-lifecycle-operation-safety" ];
}
