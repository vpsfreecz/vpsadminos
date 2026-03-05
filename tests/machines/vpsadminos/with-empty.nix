{ pkgs, config }:
{
  config = {
    imports = [
      config
    ];

    boot.zfs.pools = { };
  };
}
