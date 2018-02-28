{ config, pkgs, ... }:

# ISO configuration runnable in qemu

{
  imports = [ ./conf_iso.nix ./qemu.nix ];
}
