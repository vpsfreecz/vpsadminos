{ pkgs, ... }:
let
  defaultKernelVersion = "5.10.140";
  kernels = {
    "5.10.145" = {
      url = linuxGhUrl vpsfGh "df32d9a83a64db4e535d12ff1dec5b9cdb11a37a";
      sha256 = "sha256-FbTbW1gnTptoYUm+4lRY09wU89xUVJhao60ZX+pX760=";
      zfs = {
        rev = "5d5052188c4195ce3a79bcc58351745da8d2c068";
        sha256 = "sha256-+Yz0ARhUeY7Jgfp55fclYf+WDRZ2Zh8/YRZezxWUgcg=";
      };
    };
    "5.10.144" = {
      url = linuxGhUrl vpsfGh "4ae9182d68daa5ff3a375ec7966da900bcfe60b0";
      sha256 = "sha256-GRc5zHxRlz14jSRX3mvhNOS2oJf9amv6uwNh0495QjM=";
      zfs = {
        rev = "7d1b01d35f7ae4d4d70fc91cc58800be7417b1c0";
        sha256 = "sha256-VAg8A0ubqd0yBgD4Vksoaj5bu47+xGJXe6GJVBE5qwk=";
      };
    };
    "5.10.140" = {
      url = linuxGhUrl vpsfGh "fcdd66dc3fbe39f26a813b2f25727a721727f2ed";
      sha256 = "sha256-peRLVRC0hp0CIHcplZjx+lgASxCvfeQhjSFcN75ZkRc=";
      zfs = {
        rev = "cf79c5d7e3185db69f41452e3ebbe0576a8c5dd5";
        sha256 = "sha256-HLizndgrsOboRkIlmCfEfGFwoXweamkkddKdnQxSWWU=";
      };
    };
    "5.10.117" = {
      url = linuxGhUrl vpsfGh "6a7f96cfb71f39f91c8320d74987271071e698e2";
      sha256 = "sha256-MoFyHc7EmmF17A7yaPO0STOkzvusOUBsHhiyb7S3Zls=";
      zfs = {
        rev = "cf79c5d7e3185db69f41452e3ebbe0576a8c5dd5";
        sha256 = "sha256-HLizndgrsOboRkIlmCfEfGFwoXweamkkddKdnQxSWWU=";
      };
    };
    "5.10.98" = {
      url = linuxGhUrl vpsfGh "c0533a6a6b4af2f37863ad1626edaced4dc4edc6";
      sha256 = "sha256-EqoVOFT/CxIV4zd2eOCM78TBBjUYU7Jrj+86yOwaK0A=";
      zfs = {
        rev = "cf79c5d7e3185db69f41452e3ebbe0576a8c5dd5";
        sha256 = "sha256-HLizndgrsOboRkIlmCfEfGFwoXweamkkddKdnQxSWWU=";
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
