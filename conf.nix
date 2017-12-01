{ config, pkgs, ... }:

# Development (QEMU) configuration
# uses static IP, creates lxcbr bridge with DHCP and NAT for containers

{
  imports = [ ./conf_common.nix ./qemu.nix ];
  networking.hostName = "vpsadminos";
  networking.static.enable = true;
  networking.lxcbr = true;
  networking.nat = true;
  networking.dhcpd = true;

  vpsadminos.nix = true;
  environment.systemPackages = with pkgs; [
    vim
    screen
    strace
  ];
}
