pkgs: {
  disks = [
    {
      type = "file";
      device = "{machine}-sda.img";
      size = "10G";
    }
  ];

  config = {
    imports = [
      ../configs/base.nix
      ../configs/pool-tank.nix
    ];
  };
}
