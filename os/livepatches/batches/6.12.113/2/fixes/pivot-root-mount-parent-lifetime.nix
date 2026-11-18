{
  id = "pivot-root-mount-parent-lifetime";
  patchIds = [ "namespace-check-mounts-before-pivot-parent" ];
  provenance = {
    source = {
      repository = "vpsfreecz/linux";
      commit = "6d5a58005bd774f93600580925517da48d4842be";
    };
    status = "stable";
    upstream = "6b7c001eb5857fa09041f47673666060a2e5fc1c";
    stable = "3c2441e21c3df867e4131e0ff784ecdb3a7a55f8";
  };
  cves = [ "CVE-2026-98985" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "__x64_sys_pivot_root";
      sympos = 0;
    }
    {
      object = "vmlinux";
      symbol = "__ia32_sys_pivot_root";
      sympos = 0;
    }
  ];
  oracleIds = [ "pivot-root-operation-safety" ];
}
