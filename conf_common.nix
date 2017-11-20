{ config, pkgs, lib, ... }:

# Common configuration

{
  imports = [ ./qemu.nix ];
  networking.hostName = lib.mkDefault "vpsadminos";
  services.openssh.enable = lib.mkDefault true;
  vpsadminos.nix = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    less
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

  users.extraUsers.lxc = {
    isNormalUser = true;
    home = "/home/lxc";
    subUidRanges = [
        { startUid = 100000; count = 65536; }
      ];
    subGidRanges = [
        { startGid = 100000; count = 65536; }
      ];
  };

  users.motd = ''

    Welcome to vpsAdminOS

    Start test container with:

      lxc-create -n ct_gentoo -t download -- -d gentoo -r current -a amd64
      lxc-create -n ct_alpine -t download -- -d alpine -r edge -a amd64
      lxc-create -n ct_fedora -t download -- -d fedora -r 26 -a amd64
      lxc-create -n ct_arch   -t download -- -d archlinux -r current -a amd64
      lxc-create -n ct_ubuntu -t download -- -d ubuntu -r zesty -a amd64
    '';

  programs.ssh.package = pkgs.openssh;
}
