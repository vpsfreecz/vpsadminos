{
  lib,
  ...
}:

{
  imports = [
    ./qemu.nix
    ./local-dev-qemu.nix
  ];

  boot.zfsBuiltin = lib.mkForce false;
}
