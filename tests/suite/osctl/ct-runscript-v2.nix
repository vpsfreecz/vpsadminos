import ./ct-runscript-base.nix {
  name = "v2";
  config =
    { config, ... }:
    {
      boot.enableUnifiedCgroupHierarchy = true;
    };
}
