pkgs: {
  disks = [
    { type = "file"; device = "sda.img"; size = "10G"; }
  ];

  config = {
    imports = [ ../configs/base.nix ];

    boot.zfs.pools.tank = {
      layout = [
        { devices = [ "sda" ]; }
      ];
      doCreate = true;
      install = true;
    };
  };
}
