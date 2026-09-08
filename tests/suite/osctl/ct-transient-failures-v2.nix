import ./ct-transient-failures-base.nix {
  name = "v2";
  config.boot.enableUnifiedCgroupHierarchy = true;
}
