{ config, lib, pkgs, ... }:
with lib.kernel;
let
  availableKernels = import ./available-kernels.nix;

  inherit (availableKernels) kernels;

  vpsfGh = "https://github.com/vpsfreecz";

  repoGhUrl = gh: repo: commit: "${gh}/${repo}/archive/${commit}.tar.gz";

  linuxGhUrl = gh: commit: repoGhUrl gh "linux" commit;

  genKernelPackage = kernelVersion: pkgs.callPackage ../../packages/linux {
    inherit kernelVersion;
    url = linuxGhUrl vpsfGh kernels.${kernelVersion}.rev;
    sha256 = kernels.${kernelVersion}.sha256;
    features = if builtins.hasAttr "features" kernels.${kernelVersion}
               then kernels.${kernelVersion}.features
               else {};
  };

  genKernelPackageWithZfsBuiltin = {kernelVersion, zfsBuiltinPkg}:
    (pkgs.callPackage ../../packages/linux {
      inherit kernelVersion;
      url = linuxGhUrl vpsfGh kernels.${kernelVersion}.rev;
      sha256 = kernels.${kernelVersion}.sha256;
      zfsBuiltinPkg = zfsBuiltinPkg;
      features = lib.mkMerge
        [ (
            if builtins.hasAttr "features" kernels.${kernelVersion}
            then kernels.${kernelVersion}.features
            else {}
          )
          { zfsBuiltin = true; }
        ];
    });

  genZfsBuiltinPackage = kernel: (pkgs.callPackage ../../packages/zfs {
      configFile = "builtin";
      kernel = kernel;
      rev = kernels.${kernel.version}.zfs.rev;
      sha256 = kernels.${kernel.version}.zfs.sha256;
    }).zfsStable { enableDebug = config.system.vpsadminos.zfsDebug; };

  genZfsUserPackage = kernelVersion: (pkgs.callPackage ../../packages/zfs {
      configFile = "user";
      rev = kernels.${kernelVersion}.zfs.rev;
      sha256 = kernels.${kernelVersion}.zfs.sha256;
    }).zfsStable { enableDebug = config.system.vpsadminos.zfsDebug; };
in
{
  defaultVersion = if config.system.vpsadminos.enableUnstable
                   then availableKernels.unstableKernelVersion
                   else availableKernels.stableKernelVersion;
  inherit genKernelPackage genKernelPackageWithZfsBuiltin genZfsBuiltinPackage genZfsUserPackage kernels;
}
