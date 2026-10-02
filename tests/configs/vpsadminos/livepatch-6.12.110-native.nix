{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Native 6.12.110 continuity tests boot the reviewed .110 candidate itself.
  # The pins mirror os/packages/linux/available-kernels.nix ("6.12.110" entry),
  # and the shape mirrors the 6.12.95 boot-base config: the same-version safety
  # net that a later staging pin could change is replaced by the exact reviewed
  # source/ZFS revisions.
  mkKernel =
    zfsBuiltinPkg:
    pkgs.callPackage ../../../os/packages/linux {
      kernelVersion = "6.12.110";
      url = "https://github.com/vpsfreecz/linux/archive/1e8231622eee447c960f75840340702a12675322.tar.gz";
      sha256 = "sha256-aKj3F7leLjraNREhxE85CBb6pSsVHkFmXFeg47+LtNc=";
      inherit zfsBuiltinPkg;
      # Preserve the original package declaration, including its unevaluated
      # merge marker. Normalizing it would change the historical ZFS config.
      features =
        if zfsBuiltinPkg == null then
          { }
        else
          lib.mkMerge [
            { }
            { zfsBuiltin = true; }
          ];
    };
  plainKernel = mkKernel null;
  zfsBuiltin =
    (pkgs.callPackage ../../../os/packages/zfs {
      configFile = "builtin";
      kernel = plainKernel;
      rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
      sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
    }).zfsStable
      { enableDebug = config.system.vpsadminos.zfsDebug; };
in
{
  boot.kernelVersion = lib.mkForce "6.12.110";
  boot.kernelForBuiltinsConfig = lib.mkForce plainKernel;
  boot.zfsBuiltinPkg = lib.mkForce zfsBuiltin;
  boot.kernelPackage = lib.mkForce (mkKernel (if config.boot.zfsBuiltin then zfsBuiltin else null));
}
