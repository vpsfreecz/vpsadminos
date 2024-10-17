{ config, lib, pkgs, ... }:
with lib.kernel;
let
  stableKernelVersion = "6.10.12";
  unstableKernelVersion = "6.10.12";

  kernels = {
    "6.10.12" = {
      url = linuxGhUrl vpsfGh "fb63ad71c1e9811d576d5d89888ef0d371781c52";
      sha256 = "sha256-3Q6KCWBnG0P3LEqmQqvvgigcNO23bOoWIB9welrquUo=";
      zfs = {
        rev = "aeadd04cd9338e6d4ee3b7e2cbf999a66d127fde";
        sha256 = "sha256-dL9H6w/6+65QdqdlvSTWrJT2p60e/nZ4XktkkAeFmYE=";
      };
    };
    "6.10.11" = {
      url = linuxGhUrl vpsfGh "d2926bd25028418b7c1f97287d6b53c03c7f4f2e";
      sha256 = "sha256-Yb9gqj4Lad3o+lUMJFq/XfTXU6Grw/K2XqiGRhdT7cQ=";
      zfs = {
        rev = "76906127e558c6499fbf5421d44ea3587d359d58";
        sha256 = "sha256-E8VWxGdMbCiIob5LPsNMZLbYLjznDCVmSfyvTPI1qtQ=";
      };
    };
    "6.10.10" = {
      url = linuxGhUrl vpsfGh "744b7fe9e585bda8cd701842a3ebe5838b4bc80d";
      sha256 = "sha256-yDALdZPsyasv9r6xHPgWxELrSFga18+LHE4SW71sTQw=";
      zfs = {
        rev = "57741fa7d5b2c72ac66456f4b7aeb4fa713b3f79";
        sha256 = "sha256-1r6xS00hZtvz2SPkDsCBgZsdWoMPRHoMJ1i+j2TwxtU=";
      };
    };
    "6.9.12-2" = {
      url = linuxGhUrl vpsfGh "3a74cce5425ef5182df2410e62923b4c0b3ea899";
      sha256 = "sha256-7AhUVFT9AKkkcJPjyEsFz1r4ydk4lGfFUrf0kj2XEB0=";
      zfs = {
        rev = "108ef81d863b6fa09bb8f69a5c4abb399bd8e809";
        sha256 = "sha256-MN4YahF1hGLsLmVDeA9li5UlpMKo1iCBiQSEuO37zaU=";
      };
    };
    "6.9.12" = {
      url = linuxGhUrl vpsfGh "08bc939161a5f81e2139af7efb3e93164b6d2223";
      sha256 = "sha256-rQOO0TOVX+2Tr+C07sLICQnPxkf1gly1+z21OOdelYg=";
      zfs = {
        rev = "108ef81d863b6fa09bb8f69a5c4abb399bd8e809";
        sha256 = "sha256-MN4YahF1hGLsLmVDeA9li5UlpMKo1iCBiQSEuO37zaU=";
      };
    };
    "6.9.5" = {
      url = linuxGhUrl vpsfGh "e9932034206ad5f43eb1a34eaeeba08863e1cc91";
      sha256 = "sha256-7Nj9B4wNd0PCKCUVjSIfnMPF49hdkLKD2y11uVqEs/k=";
      zfs = {
        rev = "83b3eea02f6f0cbdd89e3390fbbc6c8b36663625";
        sha256 = "sha256-jLoGpvZviCVwULHCrB0pGGVOkp2J3NgKYKzrMYX/E2o=";
      };
    };
    "6.8.8-2" = {
      url = linuxGhUrl vpsfGh "e6bca12daad5f9a77fe14eee5d3a98214c9cbafc";
      sha256 = "sha256-K4IrPWCLlia8IX/dMlwga2gfIhgmJr+loRZzHOy010M=";
      zfs = {
        rev = "a43a2fa992cc2f3241c426d65969d59d74cd12be";
        sha256 = "sha256-jFGT2MS53BmMq/Taw35LfT//c2bZfilTMAJiEgJGHCg=";
      };
    };
    "6.6.21" = {
      url = linuxGhUrl vpsfGh "86e0c00fd80469aea354b9fc4ca5913d33ea0d92";
      sha256 = "sha256-zJHOmvyBr0aR97boNZHtfBJviqpmv69RNKqR6eBkJ9A=";
      zfs = {
        rev = "5ee3b2fc6eba2df3b2a4501ccf6c469ebd7889ed";
        sha256 = "sha256-jebuLXVqFPoASF4OptpcCHPSvynGIHiIZgw+nDHtGeU=";
      };
    };
    "6.1.53-230601" = {
      url = linuxGhUrl vpsfGh "7e286fd8bc809089a52a4c12cfdec98a4039dd0e";
      sha256 = "sha256-22vhRnZImmmMAj6GL6sV2mrR+s1vU734bPGXoGhKBKg=";
      zfs = {
        rev = "306e7db566e74f5e1d9d720fc2ea3fc016bd2b8f";
        sha256 = "sha256-dmNDDE2GCBkOC6acWBPB3wJQiP/aTCcIGa+2BDfuH6M=";
      };
    };
  };

  vpsfGh = "https://github.com/vpsfreecz";
  repoGhUrl = gh: repo: commit: "${gh}/${repo}/archive/${commit}.tar.gz";
  linuxGhUrl = gh: commit: repoGhUrl gh "linux" commit;

  genKernelPackage = kernelVersion: pkgs.callPackage ../../packages/linux {
    inherit kernelVersion;
    url = kernels.${kernelVersion}.url;
    sha256 = kernels.${kernelVersion}.sha256;
    features = if builtins.hasAttr "features" kernels.${kernelVersion}
               then kernels.${kernelVersion}.features
               else {};
  };

  genKernelPackageWithZfsBuiltin = {kernelVersion, zfsBuiltinPkg}:
    (pkgs.callPackage ../../packages/linux {
      inherit kernelVersion;
      url = kernels.${kernelVersion}.url;
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
    }).zfsStable;

  genZfsUserPackage = kernelVersion: (pkgs.callPackage ../../packages/zfs {
      configFile = "user";
      rev = kernels.${kernelVersion}.zfs.rev;
      sha256 = kernels.${kernelVersion}.zfs.sha256;
    }).zfsStable;
in
{
  defaultVersion = if config.system.vpsadminos.enableUnstable
                   then unstableKernelVersion
                   else stableKernelVersion;
  inherit genKernelPackage genKernelPackageWithZfsBuiltin genZfsBuiltinPackage genZfsUserPackage kernels;
}
