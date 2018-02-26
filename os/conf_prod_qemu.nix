{ config, pkgs, ... }:

# Production configuration runnable in qemu

{
  imports = [ ./conf_prod.nix ./qemu.nix ];

  tty.autologin.enable = true;
}
