{ config, pkgs, lib, ... }:
with lib;
{
  imports = optionals
    (lib.pathExists ../../os/configs/tests.nix)
    (trace "Using os/configs/tests.nix" [ ../../os/configs/tests.nix ]);

  boot.kernelParams = [ "root=/dev/vda" ];
  boot.initrd.kernelModules = [
    "virtio" "virtio_pci" "virtio_net" "virtio_rng" "virtio_blk" "virtio_console"
  ];

  networking.hostName = mkDefault "vpsadminos";
  networking.static.enable = mkDefault true;
  networking.lxcbr.enable = mkDefault true;
  networking.nameservers = mkDefault [ "10.0.2.3" ];
  osctl.test-shell.enable = true;
  tty.autologin.enable = mkDefault true;
  services.haveged.enable = mkDefault true;
  os.channel-registration.enable = mkDefault false;
}
