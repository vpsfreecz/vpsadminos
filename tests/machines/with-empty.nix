{ pkgs, config }:
{
  config = {
    imports = [
      ../configs/base.nix
      config
    ];

    boot.zfs.pools = {};
  };
}
