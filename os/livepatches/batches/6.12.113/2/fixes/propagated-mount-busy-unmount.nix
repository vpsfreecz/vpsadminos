{
  id = "propagated-mount-busy-unmount";
  patchIds = [ "fs-preserve-busy-propagated-mounts" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "97c9ca40b67eafbe61a253e28cd51dddb7c6bec4";
    };
    status = "stable";
    upstream = "6857e209015f95be7a8f19a9cd5dac345b9b9859";
    stable = "97c9ca40b67eafbe61a253e28cd51dddb7c6bec4";
  };
  cves = [ "CVE-2026-98996" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "propagate_mount_busy";
      sympos = 0;
    }
  ];
  oracleIds = [ ];
}
