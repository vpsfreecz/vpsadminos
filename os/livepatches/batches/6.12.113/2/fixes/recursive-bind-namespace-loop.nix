{
  id = "recursive-bind-namespace-loop";
  patchIds = [ "namespace-reject-recursive-bind-loop" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "b82f3c1131456537a514595c3991b62652507c9d";
    };
    status = "stable";
    upstream = "c640a01a78e42302879006ed7b7d5a9a943ba815";
    stable = "b82f3c1131456537a514595c3991b62652507c9d";
  };
  cves = [ "CVE-2026-98989" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "do_move_mount";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "path_mount";
      sympos = 0;
    }
  ];
  oracleIds = [ "recursive-bind-operation-safety" ];
}
