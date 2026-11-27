{
  id = "mount-expiry-locked-mount";
  patchIds = [ "namespace-never-expire-locked-mount" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "6c8013ea84fcc51cf26aa870b61b5388c7196ed5";
    };
    status = "stable";
    upstream = "f78ddcc872248c7aa1d7e904928441a0be4c6d5d";
    stable = "6c8013ea84fcc51cf26aa870b61b5388c7196ed5";
  };
  cves = [ "CVE-2026-98978" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "mark_mounts_for_expiry";
      sympos = 0;
    }
    {
      object = "vmlinux";
      symbol = "path_umount";
      sympos = 0;
    }
  ];
  oracleIds = [ ];
}
