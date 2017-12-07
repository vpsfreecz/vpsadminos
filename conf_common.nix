{ config, pkgs, lib, ... }:

# Common configuration

{
  imports = [ ./qemu.nix ];
  networking.hostName = lib.mkDefault "vpsadminos";
  services.openssh.enable = lib.mkDefault true;
  vpsadminos.nix = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    less
    openssh
    ruby
    osctl
    osctld
    ];

  environment.etc = {
  };

  users.extraUsers.root = {
    openssh.authorizedKeys.keys = lib.mkDefault (with import ./ssh-keys.nix; [ aither snajpa snajpa_e srk srk_devel ]);
    subUidRanges = [
        { startUid = 666000; count = 65536; }
      ];
    subGidRanges = [
        { startGid = 666000; count = 65536; }
      ];
  };

  users.motd = ''

    Welcome to vpsAdminOS

    Create a zpool:
      dd if=/dev/zero of=/lxc.zpool bs=1M count=4096 && zpool create lxc /lxc.zpool

    Run osctld:
      osctld

    Fetch OS templates:
      wget https://s.hvfn.cz/~aither/pub/tmp/templates/ubuntu-16.04-x86_64-vpsfree.tar.gz
      wget https://s.hvfn.cz/~aither/pub/tmp/templates/debian-9-x86_64-vpsfree.tar.gz
      wget https://s.hvfn.cz/~aither/pub/tmp/templates/centos-7.3-x86_64-vpsfree.tar.gz
      wget https://s.hvfn.cz/~aither/pub/tmp/templates/alpine-3.6-x86_64-vpsfree.tar.gz

    Create a user:
      osctl user new --ugid 5000 --offset 666000 --size 65536 myuser01

    Create a container:
      osctl ct new --user myuser01 --template ubuntu-16.04-x86_64-vpsfree.tar.gz myct01

    Configure container routing:
      osctl ct set --route-via 10.100.10.100/30 myct01
      osctl ct ip add myct01 1.2.3.4

    Start the container:
      osctl ct start myct01

    Further information:
      osctl help user
      osctl help ct
    '';

  programs.ssh.package = pkgs.openssh;
}
