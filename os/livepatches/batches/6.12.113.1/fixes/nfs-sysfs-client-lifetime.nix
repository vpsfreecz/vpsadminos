{
  id = "nfs-sysfs-client-lifetime";
  patchIds = [ "nfs-drain-server-sysfs-before-client-release" ];
  provenance = {
    source = {
      repository = "vpsfreecz/linux";
      commit = "02beaa9040c47f489991bac14c0bdc00b7a737c9";
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
      symbol = "nfs_free_server";
      sympos = 0;
    }
    {
      object = "vmlinux";
      symbol = "nfs_init_server.isra.0";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "shutdown_store";
      sympos = 1;
    }
  ];
  oracleIds = [ "nfs-client-operation-safety" ];
}
