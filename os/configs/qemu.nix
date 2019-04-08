{ configs, pkgs, lib, ... }:

{
  imports = [ ./common.nix ];

  boot.kernelParams = [ "root=/dev/vda" ];
  boot.initrd.kernelModules = [ "virtio" "virtio_pci" "virtio_net" "virtio_rng" "virtio_blk" "virtio_console" ];

  networking.hostName = "vpsadminos";
  networking.static.enable = true;
  networking.lxcbr = true;
  networking.nat = true;
  networking.dhcpd = true;

  system.qemuDisks = lib.mkDefault [
    { device = "sda.img"; type = "file"; size = "8G"; create = true; }
  ];

  boot.zfs.pools = lib.mkDefault {
    tank = {
      layout = [
        { devices = [ "sda" ]; }
      ];
      doCreate = true;
      install = true;
    };
  };

  vpsadminos.nix = true;
  tty.autologin.enable = true;
  services.haveged.enable = true;

  users.motd = ''

    Welcome to vpsAdminOS

    Configure osctld:
      osctl pool install tank

    Create a user:
      osctl user new --map 0:666000:65536 myuser01

    Create a container:
      osctl ct new --user myuser01 --distribution alpine --version latest myct01

    Configure container networking:
      osctl ct netif new routed myct01 eth0
      osctl ct netif ip add myct01 eth0 1.2.3.4/32

    Start the container:
      osctl ct start myct01

    More information:
      man osctl
    '';
}
