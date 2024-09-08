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

  os.channel-registration.enable = lib.mkDefault true;
  services.openssh.settings.PermitRootLogin = lib.mkDefault "yes";

  isoImage.makeUsbBootable = true;
  isoImage.makeEfiBootable = true;

  hardware.enableRedistributableFirmware = true;
}
