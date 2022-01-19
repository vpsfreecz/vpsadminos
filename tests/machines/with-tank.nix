{ pkgs, config }:
{
  disks = [
    { type = "file"; device = "sda.img"; size = "10G"; }
  ];

  config = {
    imports = [
      ../configs/base.nix
      ../configs/pool-tank.nix
      config
    ];
  };
}
