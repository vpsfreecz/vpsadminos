{ config, pkgs, lib, ... }:

# Common configuration

{
  imports = [ ];
  networking.hostName = lib.mkDefault "vpsadminos";
  services.openssh.enable = lib.mkDefault true;
  vpsadminos.nix = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    less
    manpages
    openssh
    osctl
    osctld
    ruby
    ];

  environment.etc = {
  };

  users.extraUsers.root = {
    openssh.authorizedKeys.keys = lib.mkDefault (with import ./ssh-keys.nix; [ aither snajpa srk srk_devel ]);
    subUidRanges = [
        { startUid = 666000; count = 65536; }
      ];
    subGidRanges = [
        { startGid = 666000; count = 65536; }
      ];
    };

  users.extraUsers.migration = {
    isSystemUser = true;
    description = "User for container migrations";
    home = "/run/osctl/migration";
    shell = pkgs.bashInteractive;
  };

  users.motd = ''

    Welcome to vpsAdminOS

    Create a zpool:
      dd if=/dev/zero of=/tank.zpool bs=1M count=4096 && zpool create tank /tank.zpool

    Configure osctld:
      osctl pool install tank

    Fetch OS templates:
      wget https://s.hvfn.cz/~aither/pub/tmp/templates/ubuntu-16.04-x86_64-vpsfree.tar.gz
      wget https://s.hvfn.cz/~aither/pub/tmp/templates/debian-9-x86_64-vpsfree.tar.gz
      wget https://s.hvfn.cz/~aither/pub/tmp/templates/centos-7.3-x86_64-vpsfree.tar.gz
      wget https://s.hvfn.cz/~aither/pub/tmp/templates/alpine-3.6-x86_64-vpsfree.tar.gz

    Create a user:
      osctl user new --ugid 5000 --offset 666000 --size 65536 myuser01

    Create a container:
      osctl ct new --user myuser01 --template ubuntu-16.04-x86_64-vpsfree.tar.gz myct01

    Configure container networking:
      osctl ct netif new routed --via 10.100.10.100/30 myct01 eth0
      osctl ct netif ip add myct01 eth0 1.2.3.4/32

    Start the container:
      osctl ct start myct01

    More information:
      man osctl
    '';

  programs.ssh.package = pkgs.openssh;
}
