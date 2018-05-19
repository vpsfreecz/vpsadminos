{ config, pkgs, lib, ... }:

# Common configuration

{
  # import local configuration (local.nix) if it exists
  imports = [ ] ++ lib.optionals (lib.pathExists ./local.nix) [ ./local.nix ];
  networking.hostName = lib.mkDefault "vpsadminos";
  services.openssh.enable = lib.mkDefault true;
  vpsadminos.nix = lib.mkDefault true;

  boot.supportedFilesystems = [ "nfs" ];
  boot.initrd.supportedFilesystems = [ "zfs" ];

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

  users.extraUsers.repository = {
    isSystemUser = true;
    description = "User for remote repository access/cache";
    home = "/run/osctl/repository";
  };

  users.motd = ''

    Welcome to vpsAdminOS

    Configure osctld:
      osctl pool install tank

    Create a user:
      osctl user new --ugid 5000 --map 0:666000:65536 myuser01

    Create a container:
      osctl ct new --user myuser01 --distribution alpine --version 3.7 myct01

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
