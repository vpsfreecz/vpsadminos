import ./ct-transient-failures-base.nix {
  name = "v1";
  config.boot.enableUnifiedCgroupHierarchy = false;
}
