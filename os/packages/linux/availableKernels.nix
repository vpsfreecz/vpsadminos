{ pkgs, lib, ... }:
with lib.kernel;
let
  defaultKernelVersion = "6.8.9";
  kernels = {
    "6.8.10" = {
      url = linuxGhUrl vpsfGh "84107397de8f9982b5fe78f0e5e85e711ad39ea2";
      sha256 = "sha256-NfcWPVk/+xaRVgY4hAbjwITv2HEkY6I9K9kyobmN+zA=";
      zfs = {
        rev = "a43a2fa992cc2f3241c426d65969d59d74cd12be";
        sha256 = "sha256-jFGT2MS53BmMq/Taw35LfT//c2bZfilTMAJiEgJGHCg=";
      };
    };
    "6.8.9" = {
      url = linuxGhUrl vpsfGh "77a6e927e31cb96e7989eec57a64cdcf8bea82ab";
      sha256 = "sha256-DjiljoZzrZwEQSfNdVpqiRwUqsoPLi0f+9uhdo8eCIY=";
      zfs = {
        rev = "a43a2fa992cc2f3241c426d65969d59d74cd12be";
        sha256 = "sha256-jFGT2MS53BmMq/Taw35LfT//c2bZfilTMAJiEgJGHCg=";
      };
    };
    "6.8.8" = {
      url = linuxGhUrl vpsfGh "ae6218979272ab34169282b2ac999b960808dec3";
      sha256 = "sha256-bOjzu90txhwkpAjex1EdHEeFn9kbjthJ3fwHSHA2weU=";
      zfs = {
        rev = "a43a2fa992cc2f3241c426d65969d59d74cd12be";
        sha256 = "sha256-jFGT2MS53BmMq/Taw35LfT//c2bZfilTMAJiEgJGHCg=";
      };
    };
    "6.6.28" = {
      url = linuxGhUrl vpsfGh "8406c3143b094ad6a3e46cfaf6a6dde593dbb0d3";
      sha256 = "sha256-VIHMoT9fJsSkLY79iA79//Or6jP+v8QgPElB41t9ht4=";
      zfs = {
        rev = "bd6f9480c1a12fed708b531176ee95d14a62f273";
        sha256 = "sha256-uo15ZsMnm4iVvxiL9ESSrcrkUPMNXxZGirz8ivqPDKw=";
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
    "6.6.17" = {
      url = linuxGhUrl vpsfGh "d106ce2138763744573619d1c1283ee2cf5b0fc2";
      sha256 = "sha256-uWm2zUBqfJtJYpAkw4LCBw1EjtKZ8147/rHEFAmBIbQ=";
      zfs = {
        rev = "639b42ba4c5131ba289124b90e4dc194f62fa91f";
        sha256 = "sha256-hAmZ+YWwbKfb0MC7W8BZdb3A8JtILAOkCU1fetDyADA=";
      };
    };
    "6.6.13" = {
      url = linuxGhUrl vpsfGh "152554781bc14029a8ba1dc4384f3124cf9730ce";
      sha256 = "sha256-v02M+cNrgVBtG0YjQ1B252TJx8Wh2Fm5ZE9+H1SpfHk=";
      zfs = {
        rev = "af4510166503cc0667841e61959375071a0e4df7";
        sha256 = "sha256-kEn/vso5oBpCdD58ipRVsfbO0BnL3j9yjD3mNY7PrK0=";
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
    "6.1.44" = {
      url = linuxGhUrl vpsfGh "d0a65a38bb85a3566c8d32055e3e679504ec2565";
      sha256 = "sha256-A9ZCxkzEmNCpHKk+QdLgZe0EUW40N8qTz+4KoBVNPkg=";
      zfs = {
        rev = "0caed299195a2fb9904aa85fbd4781729fecd6cc";
        sha256 = "sha256-o+Z0TwH7HjH1MRIIXmHBc7+/B61eUSWQKMwD4U/jfZg=";
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
  defaultVersion = defaultKernelVersion;
  inherit genKernelPackage genKernelPackageWithZfsBuiltin genZfsBuiltinPackage genZfsUserPackage kernels;
}
