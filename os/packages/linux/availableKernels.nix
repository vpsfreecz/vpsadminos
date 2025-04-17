{ config, lib, pkgs, ... }:
with lib.kernel;
let
  stableKernelVersion = "6.12.21";
  unstableKernelVersion = "6.12.23";

  kernels = {
    "6.12.23" = {
      url = linuxGhUrl vpsfGh "1f80823be8dddd1d5298a342b4a858a865b89e41";
      sha256 = "sha256-Xgacpu0kmVNBE47E3jISfh9+xvElULUYynLuA9UwdNk=";
      zfs = {
        rev = "2e0b21efb538eb3818301d9dce082f968cb073ae";
        sha256 = "sha256-Glpr7WEoYwd/49sZpijouvVHdKxsgpF+jNlR5Wmr3ZM=";
      };
    };
    "6.12.21" = {
      url = linuxGhUrl vpsfGh "50e5042ca2a1c500f2ddbeffa428f756a23ccdc5";
      sha256 = "sha256-rsZoMNtyh0yJ9Yy4NyLKDx7h0Z2fP9ZUK+Z9lLW2Roc=";
      zfs = {
        rev = "4821e1dc9b6479dcd1bfb992bf93aee993ffe74a";
        sha256 = "sha256-pYlNMeO2dNgAp8gqruV9uW5vEdHCXWGWmnDNLk1yIA8=";
      };
    };
    "6.12.20" = {
      url = linuxGhUrl vpsfGh "703788126d55b6941c9bd9608c44a63c9050d68a";
      sha256 = "sha256-pqvyUZbce7NLWKywYYxkGv3uAx5yB5TmlcVV1ANTaUc=";
      zfs = {
        rev = "4821e1dc9b6479dcd1bfb992bf93aee993ffe74a";
        sha256 = "sha256-pYlNMeO2dNgAp8gqruV9uW5vEdHCXWGWmnDNLk1yIA8=";
      };
    };
    "6.12.19" = {
      url = linuxGhUrl vpsfGh "30e88cf3452fc7aca8130fed57977375059c21c9";
      sha256 = "sha256-86U9aJ9Pw5cfh3NMdWT1RIPftpZg7g6uHt7kZM/INOA=";
      zfs = {
        rev = "091ba330df7fc1a442de37bdc5f86d251562e3f7";
        sha256 = "sha256-/Wh9bzaerjGJWxo7yD4LMoUW+0tazCI2Aw7M49Gwmi4=";
      };
    };
    "6.12.18" = {
      url = linuxGhUrl vpsfGh "2c0d5e8bd235b3fb049a95c687d345a6cebe0f1c";
      sha256 = "sha256-WlUvQgW7MoixL68ZB3Yc729+A5mBxYf8tcmaph8QXYc=";
      zfs = {
        rev = "091ba330df7fc1a442de37bdc5f86d251562e3f7";
        sha256 = "sha256-/Wh9bzaerjGJWxo7yD4LMoUW+0tazCI2Aw7M49Gwmi4=";
      };
    };
    "6.12.14" = {
      url = linuxGhUrl vpsfGh "bb5e22767d0ec527b33e7aa699d67ab8c51275b8";
      sha256 = "sha256-dbkgxby2ug71KSfT3DF8DfRLcifiX1Z/Mw/lXS6+mLA=";
      zfs = {
        rev = "2b287937fa5695fbb964fd9923817569353d85e8";
        sha256 = "sha256-bgSZ3O0DBr3KwE027/tO8tdzZpEUs8h5rQKpgVG9YWY=";
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
    }).zfsStable { enableDebug = config.system.vpsadminos.zfsDebug; };

  genZfsUserPackage = kernelVersion: (pkgs.callPackage ../../packages/zfs {
      configFile = "user";
      rev = kernels.${kernelVersion}.zfs.rev;
      sha256 = kernels.${kernelVersion}.zfs.sha256;
    }).zfsStable { enableDebug = config.system.vpsadminos.zfsDebug; };
in
{
  defaultVersion = if config.system.vpsadminos.enableUnstable
                   then unstableKernelVersion
                   else stableKernelVersion;
  inherit genKernelPackage genKernelPackageWithZfsBuiltin genZfsBuiltinPackage genZfsUserPackage kernels;
}
