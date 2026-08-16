{
  config,
  pkgs,
  lib,
  ...
}:
let
  kernelPackages = import ../packages/linux/packages.nix {
    inherit config lib pkgs;
  };
  devLib = ../lib/dev;

  localKernelStage = builtins.getEnv "VPSADMINOS_LOCAL_KERNEL_STAGE";
  localZfsStage = builtins.getEnv "VPSADMINOS_LOCAL_ZFS_STAGE";
  localKernelStagePath = if localKernelStage == "" then null else /. + localKernelStage;
  localZfsStagePath = if localZfsStage == "" then null else /. + localZfsStage;
  kernelVersionEnv = builtins.getEnv "VPSADMINOS_LOCAL_KERNEL_VERSION";
  stageMeta =
    if localKernelStagePath == null || !(builtins.pathExists (localKernelStagePath + "/meta.nix")) then
      null
    else
      import (localKernelStagePath + "/meta.nix");

  kernelVersion =
    if kernelVersionEnv != "" then
      kernelVersionEnv
    else if stageMeta != null then
      stageMeta.version
    else
      kernelPackages.defaultVersion;
  kernelDef =
    if builtins.hasAttr kernelVersion kernelPackages.kernels then
      kernelPackages.kernels.${kernelVersion}
    else
      { };
  kernelFeatures = if builtins.hasAttr "features" kernelDef then kernelDef.features else { };

  stagedKernel =
    if localKernelStage == "" then
      null
    else
      import (devLib + "/local-kernel-package.nix") {
        inherit pkgs lib;
        stage = localKernelStage;
        features = kernelFeatures;
      };

  stagedZfsKernel =
    if localZfsStage == "" then
      null
    else
      assert stagedKernel != null;
      import (devLib + "/local-zfs-package.nix") {
        inherit pkgs lib;
        stage = localZfsStage;
        kind = "kernel";
        kernel = stagedKernel;
      };

  stagedZfsUser =
    if localZfsStagePath == null || !(builtins.pathExists (localZfsStagePath + "/user/out")) then
      null
    else
      import (devLib + "/local-zfs-package.nix") {
        inherit pkgs lib;
        stage = localZfsStage;
        kind = "user";
      };

  kernelPackagesWithStagedZfs =
    if stagedKernel == null then
      null
    else
      (pkgs.linuxPackagesFor stagedKernel).extend (
        self: super: {
          zfs = stagedZfsKernel;
        }
      );
in
lib.mkIf (stagedKernel != null || stagedZfsKernel != null || stagedZfsUser != null) {
  boot.kernelVersion = lib.mkIf (stagedKernel != null) (lib.mkForce stagedKernel.version);
  boot.kernelPackage = lib.mkIf (stagedKernel != null) (lib.mkForce stagedKernel);
  boot.kernelPackages = lib.mkIf (stagedZfsKernel != null) (lib.mkForce kernelPackagesWithStagedZfs);
  boot.zfsUserPackage = lib.mkIf (stagedZfsUser != null) (lib.mkForce stagedZfsUser);
  boot.zfsBuiltin = lib.mkIf (stagedKernel != null || stagedZfsKernel != null) (lib.mkForce false);
}
