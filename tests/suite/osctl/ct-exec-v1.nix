import ./ct-exec-base.nix {
  name = "v1";
  config =
    { config, ... }:
    {
      boot.enableUnifiedCgroupHierarchy = false;
    };
}
