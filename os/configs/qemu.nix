{ configs, pkgs, lib, ... }:

{
  boot.kernelParams = [ "root=/dev/vda" ];
  boot.initrd.kernelModules = [ "virtio" "virtio_pci" "virtio_net" "virtio_rng" "virtio_blk" "virtio_console" ];

  networking.hostName = "vpsadminos";
  networking.static.enable = true;
  networking.lxcbr = true;
  networking.nat = true;
  networking.dhcpd = true;
  networking.nameservers = [ "10.0.2.3" ];

  boot.qemu.disks = lib.mkDefault [
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

  environment.systemPackages = with pkgs; [
    git
  ];

  users.motd = ''

    Welcome to vpsAdminOS

    Configure osctld:
      osctl pool install tank

    Create a container:
      osctl ct new --distribution alpine myct01

    Configure container networking:
      osctl ct netif new routed myct01 eth0
      osctl ct netif ip add myct01 eth0 1.2.3.4/32

    Start the container:
      osctl ct start myct01

    More information:
      man osctl
    '';
}
