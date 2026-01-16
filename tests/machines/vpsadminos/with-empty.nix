{ pkgs, config }:
{
  config = {
    imports = [
      ../../configs/vpsadminos/base.nix
      config
    ];

    boot.zfs.pools = { };
  };
}
