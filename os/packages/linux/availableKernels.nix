{ pkgs, ... }:
let
  defaultKernelVersion = "5.10.149";
  kernels = {
    "5.10.149" = {
      url = linuxGhUrl vpsfGh "34e04d0236fe5a4ea8bcc458d6964f7c0e772b77";
      sha256 = "sha256-3BJRCDgLMi37Vkwn72wH88BLl1memMFvANmdFNklCQo=";
      zfs = {
        rev = "d306a1cd3fee5261b0ebdcc0e2dd9b405db2bd97";
        sha256 = "sha256-rdTeAK/kqFn0NsDAom0QVyaJGkuqGVpSXz3AubIVKYk=";
      };
    };
    "5.10.147" = {
      url = linuxGhUrl vpsfGh "a320d2e6fcf71539109473352d803aacffbbe6c1";
      sha256 = "sha256-FFuxEzqycE2j6m2KlbQMcMcmQC+rrHOeguL6pRnkCdY=";
      zfs = {
        rev = "b664d7b8d43c9a1eea348d9a8d4b132a44e13a3c";
        sha256 = "sha256-ZhweYfuAkPx2YPapNUzZSeDUqZ2+LX2W7DH+w3BJEyU=";
      };
    };
    "5.10.146" = {
      url = linuxGhUrl vpsfGh "7edef9e63fad58e34db86d901141b37b46b45086";
      sha256 = "sha256-miHofBML0j7FvYdWBz564+rfTA+J7DSBDPyk74KFRWc=";
      zfs = {
        rev = "b664d7b8d43c9a1eea348d9a8d4b132a44e13a3c";
        sha256 = "sha256-ZhweYfuAkPx2YPapNUzZSeDUqZ2+LX2W7DH+w3BJEyU=";
      };
    };
    "5.10.145" = {
      url = linuxGhUrl vpsfGh "df32d9a83a64db4e535d12ff1dec5b9cdb11a37a";
      sha256 = "sha256-FbTbW1gnTptoYUm+4lRY09wU89xUVJhao60ZX+pX760=";
      zfs = {
        rev = "779a159b5fd21ff79f8209895d3b3c867afc3a6a";
        sha256 = "sha256-L4vsVfP+LfW4oy59ROYh4qOhfkvnQ6h7DBea1vhaX6o=";
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
