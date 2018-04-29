{ config, pkgs, lib, ... }:

# Development (QEMU) configuration
# uses static IP, creates lxcbr bridge with DHCP and NAT for containers

{
  imports = [ ./common.nix ./qemu.nix ];
  networking.hostName = "vpsadminos";
  networking.static.enable = true;
  networking.lxcbr = true;
  networking.nat = true;
  networking.dhcpd = true;

  boot.zfs.pool.layout = lib.mkDefault "mirror sda sdb";

  vpsadminos.nix = true;

  tty.autologin.enable = true;

  environment.systemPackages = with pkgs; [
    glibc
    ipset
    vim
    screen
    strace
  ];
}
