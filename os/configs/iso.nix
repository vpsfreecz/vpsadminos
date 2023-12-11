{ config, lib, pkgs, ... }:

# ISO image configuration

{
  imports = [
    ../modules/installer/cd-dvd/iso-image.nix
  ];

  networking.hostName = "vpsadminos";
  networking.lxcbr.enable = true;
  networking.useDHCP = true;

  tty.autologin.enable = true;

  environment.systemPackages = with pkgs; [
    e2fsprogs
    gptfdisk
    parted
    screen
    strace
    vim
  ];

  services.openssh.settings.PermitRootLogin = lib.mkDefault "yes";

  isoImage.makeUsbBootable = true;
  isoImage.makeEfiBootable = true;

  hardware.enableRedistributableFirmware = true;
}
