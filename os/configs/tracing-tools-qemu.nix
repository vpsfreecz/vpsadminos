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

  linuxSnapshot = builtins.getEnv "VPSADMINOS_LINUX_SNAPSHOT";
  localKernelStage = builtins.getEnv "VPSADMINOS_LOCAL_KERNEL_STAGE";
  kernelVersionEnv = builtins.getEnv "VPSADMINOS_TRACING_KERNEL_VERSION";

  kernelVersion = if kernelVersionEnv == "" then kernelPackages.defaultVersion else kernelVersionEnv;
  kernelDef = kernelPackages.kernels.${kernelVersion};

  structuredExtraConfig =
    if builtins.hasAttr "structuredExtraConfig" kernelDef then
      kernelDef.structuredExtraConfig
    else
      { };
  kernelFeatures = if builtins.hasAttr "features" kernelDef then kernelDef.features else { };

  localKernel =
    if linuxSnapshot == "" then
      null
    else
      pkgs.callPackage ../packages/linux/generic.nix (rec {
        version = kernelVersion;
        modDirVersion = lib.concatStringsSep "." (lib.take 3 (lib.splitString "." "${version}.0"));
        extraMeta.branch = lib.concatStringsSep "." (lib.take 2 (lib.splitString "." version));
        src = /. + linuxSnapshot;
        kernelPatches = [ pkgs.kernelPatches.bridge_stp_helper ];
        inherit structuredExtraConfig;
        features = kernelFeatures;
        zfsBuiltinPkg = null;
      });
in
{
  imports = [ ./local-dev-qemu.nix ];

  boot.kernelVersion = lib.mkIf (localKernelStage == "") (lib.mkForce kernelVersion);
  boot.kernelPackage = lib.mkIf (localKernelStage == "" && localKernel != null) (lib.mkForce localKernel);
  boot.zfsBuiltin = lib.mkIf (localKernel != null) (lib.mkForce false);
}
