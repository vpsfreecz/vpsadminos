import ./ct-exec-base.nix {
  name = "v2";
  config =
    { config, ... }:
    {
      boot.enableUnifiedCgroupHierarchy = true;
    };
}
