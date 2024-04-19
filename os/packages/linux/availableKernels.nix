{ pkgs, lib, ... }:
with lib.kernel;
let
  defaultKernelVersion = "6.6.28";
  kernels = {
    "6.6.28" = {
      url = linuxGhUrl vpsfGh "d90a47f4a62368a5fa065b6a5424fff3004400d0";
      sha256 = "sha256-c4E02VzSRbnAZj8AizyqQwXaSg0N6v4fQZrE9PVc9hk=";
      zfs = {
        rev = "d080274c0ba0c1824383175110b1ca8baaca0120";
        sha256 = "sha256-AfuqPGqKbNhrmKHuqoQ6+cvIO9/ztWOS9VW78WXzGeA=";
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
    "6.6.1-2" = {
      url = linuxGhUrl vpsfGh "a4ab6e23a71db25c8400b21e8085d1509318af61";
      sha256 = "sha256-RIUoL7q+NO5ICjYpVRj0W4PYD2jOgWgo/3vHDrWoEwI=";
      zfs = {
        rev = "639b42ba4c5131ba289124b90e4dc194f62fa91f";
        sha256 = "sha256-hAmZ+YWwbKfb0MC7W8BZdb3A8JtILAOkCU1fetDyADA=";
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
    "6.6.10" = {
      url = linuxGhUrl vpsfGh "17d9c8ecca34126be30bb3fb52594ad8ee1cf2a2";
      sha256 = "sha256-hFrj65ISS+MImVQAMAPgUvHMGOd2d9wLVbMuQGczuZ8=";
      zfs = {
        rev = "7ae1210c27b18ddf8ccefaf4e45ca46487dfee7d";
        sha256 = "sha256-0KvWzF/RG+WUaWGJV/Hg1K3VNN8XXxlixM8FGidTaZM=";
      };
    };
    "6.6.9" = {
      url = linuxGhUrl vpsfGh "a9d2f8ebfa7e15fc2947801911892745ba0f106c";
      sha256 = "sha256-SwmGr5JIun79V32I2BfxC6FPTgE9xxSH6Keanj0zy9c=";
      zfs = {
        rev = "5b20ef272c613bb40a3aa952199f025ec62d31a5";
        sha256 = "sha256-yPd8M+VqOB2QbEHxpvvMsqCl+DkOjtr0w/YbbLaiXp0=";
      };
    };
    "6.6.1" = {
      url = linuxGhUrl vpsfGh "4dd38883a0d6c775cf8dd3e6a8cf896817e61d1b";
      sha256 = "sha256-4I0rDb0t08KRMLag4XQ0OSNYgPgLUxAqUSxTVkcD0uU=";
      zfs = {
        rev = "1edd30b631adef06ff6662413e7abc31575c8205";
        sha256 = "sha256-vmAV7fpllTDVYiBNK9wvVznMr4zL+JdRWOhutD4NA2k=";
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

  genZfsUserPackage = kernelVersion: (pkgs.callPackage ../../packages/zfs {
      configFile = "user";
      rev = kernels.${kernelVersion}.zfs.rev;
      sha256 = kernels.${kernelVersion}.zfs.sha256;
    }).zfsStable;
in
{
  defaultVersion = defaultKernelVersion;
  genKernelPackage = genKernelPackage;
  genZfsUserPackage = genZfsUserPackage;
  kernels = kernels;
}
