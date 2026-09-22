{
  config,
  lib,
  pkgs,
  ...
}:
let
  # These transition tests exercise the original livepatch ABI, not whatever
  # same-version kernel a later staging pin selects.
  mkKernel =
    zfsBuiltinPkg:
    pkgs.callPackage ../../../os/packages/linux {
      kernelVersion = "6.12.95";
      url = "https://github.com/vpsfreecz/linux/archive/a2384967b90f24d2470c9eb15f0e66d938df7e08.tar.gz";
      sha256 = "sha256-QlwV4uFeX7ZbWHMuU14rFXswmpqpb1hdVmYUAGOWRh8=";
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
      rev = "9f479d6551bebde664b71b6d7553e8d23c162c4c";
      sha256 = "sha256-arX7aWuTpmJ74YYtRgxh2MsA4ixC656GsDLcVWHhAZE=";
    }).zfsStable
      { enableDebug = config.system.vpsadminos.zfsDebug; };
in
{
  boot.kernelVersion = lib.mkForce "6.12.95";
  boot.kernelForBuiltinsConfig = lib.mkForce plainKernel;
  boot.zfsBuiltinPkg = lib.mkForce zfsBuiltin;
  boot.kernelPackage = lib.mkForce (mkKernel (if config.boot.zfsBuiltin then zfsBuiltin else null));
}
