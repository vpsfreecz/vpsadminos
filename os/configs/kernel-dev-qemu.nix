{
  lib,
  ...
}:

{
  imports = [ ./qemu.nix ];

  boot.zfsBuiltin = lib.mkForce false;
}
