{ config, pkgs, lib, ... }:

# Common configuration

{
  # import local configuration (local.nix) if it exists
  imports = [ ] ++ lib.optionals (lib.pathExists ./local.nix) [ ./local.nix ];
  networking.hostName = lib.mkDefault "vpsadminos";

  services.logrotate.enable = lib.mkDefault true;
  services.openssh.enable = lib.mkDefault true;
  services.zfs.autoScrub.enable = lib.mkDefault true;

  vpsadminos.nix = lib.mkDefault true;

  nix.daemon.enable = lib.mkDefault true;

  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  boot.supportedFilesystems = [ "nfs" ];
  boot.initrd.supportedFilesystems = [ "zfs" ];

  environment.systemPackages = with pkgs; [
    glibc
    iotop
    ipset
    less
    manpages
    ncurses
    openssh
    osctl
    osup
    ruby
    screen
    strace
    vim
  ];

  environment.etc = {
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

  programs.ssh.package = pkgs.openssh;
  programs.htop.enable = true;
}
