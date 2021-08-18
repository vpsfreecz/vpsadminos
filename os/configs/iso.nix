{ config, lib, pkgs, ... }:

# ISO image configuration

{
  imports = [
    ../modules/installer/cd-dvd/iso-image.nix
  ];

  networking.hostName = "vpsadminos";
  networking.lxcbr = true;
  networking.nat = true;
  networking.dhcp = true;
  networking.dhcpd = true;

  vpsadminos.nix = true;

  tty.autologin.enable = true;

  environment.systemPackages = with pkgs; [
    e2fsprogs
    parted
    screen
    strace
    vim
  ];

  services.openssh.permitRootLogin = lib.mkDefault "yes";

  isoImage.makeUsbBootable = true;
  isoImage.makeEfiBootable = true;

  hardware.enableRedistributableFirmware = true;
}
