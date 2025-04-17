{ config, lib, pkgs, ... }:
with lib.kernel;
let
  stableKernelVersion = "6.12.21";
  unstableKernelVersion = "6.12.23";

  kernels = {
    "6.12.23" = {
      url = linuxGhUrl vpsfGh "5dd81503a831899ececd2efb1c5cfcfe7a3d562d";
      sha256 = "sha256-DprPiBlu5ZLpzFtL3j5x2jqKsf548q7zBfh7DicWhBw=";
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
    "6.12.13" = {
      url = linuxGhUrl vpsfGh "dbe3b890168c9bdd3d742c52b7b92a085f3c6eb0";
      sha256 = "sha256-vs/nRVWK3OEB8mW8OqeoFGNWNcf55gqVz9ZzdeG7jIo=";
      zfs = {
        rev = "2b287937fa5695fbb964fd9923817569353d85e8";
        sha256 = "sha256-bgSZ3O0DBr3KwE027/tO8tdzZpEUs8h5rQKpgVG9YWY=";
      };
    };
    "6.12.11" = {
      url = linuxGhUrl vpsfGh "7a9be5748313e20df1dcc0e094d0ab5efa110e78";
      sha256 = "sha256-uGK+0kl++RQhCNU37BQwPqzl73eIhNGjkLiQhXc2fxE=";
      zfs = {
        rev = "82a17bb777b038b198314cf3e5d4d98c57ac399a";
        sha256 = "sha256-QdziamQo3F0HmQ3jdmP5OHkc0VfAaAyL3Ur0TPl7jFE=";
      };
    };
    "6.11.10" = {
      url = linuxGhUrl vpsfGh "8edcbe9a791aa22ac6b09d0b93b3cec73aa3d8c0";
      sha256 = "sha256-jwDT1+51D54zd8x5D5tndMWUx1x3CymAs+T4AqDV1Vg=";
      zfs = {
        rev = "f14f1b94404c42894b3695cc303fa2fe076dde06";
        sha256 = "sha256-7q6AWn4X+l2KGTH799r+nV1H4Y37tUGQIv6152SFXgc=";
      };
    };
    "6.11.8" = {
      url = linuxGhUrl vpsfGh "939be0e35133050511caba84dff297c489d5a2aa";
      sha256 = "sha256-qRwj/uGUhSHgAI5rnJHuZTHqdItb+NOjFMEfUr1+joQ=";
      zfs = {
        rev = "24432ce1ef15b27a1447a05b31d38f0275392470";
        sha256 = "sha256-ApZcd29c4RFfZF9YbaGTpmVoyRVt31UXSxaVpurTh/Y=";
      };
    };
    "6.10.12" = {
      url = linuxGhUrl vpsfGh "fb63ad71c1e9811d576d5d89888ef0d371781c52";
      sha256 = "sha256-3Q6KCWBnG0P3LEqmQqvvgigcNO23bOoWIB9welrquUo=";
      zfs = {
        rev = "d41953021ca5d1dfd68e882a24e91b9be9f852c3";
        sha256 = "sha256-Ts0Z5UO7OfQQfpvg1H/VoQxIyF8NXpA8M7kIIzdt6DY=";
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
