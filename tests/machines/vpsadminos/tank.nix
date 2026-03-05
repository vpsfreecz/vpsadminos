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
      ../../configs/vpsadminos/pool-tank.nix
    ];
  };
}
