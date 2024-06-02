import ./ct-runscript-base.nix {
  name = "v1";
  config =
    { config, ... }:
    {
      boot.enableUnifiedCgroupHierarchy = false;
    };
}
