{ pkgs, ... }:
let
  defaultKernelVersion = "5.10.140";
  kernels = {
    "5.10.143" = {
      url = linuxGhUrl vpsfGh "b80aff6ff47d418b8e676d1c7a9ebad5923882ab";
      sha256 = "sha256-cPMuJB12CLGSFAj3z0uvh+TAzqDGPBF4a2RxepNWU1g=";
      zfs = {
        rev = "f037e03b0157eca399dcfa4c10ffce09853c9949";
        sha256 = "sha256-oQPmmOd/8g/isxdxVYV758DjjR9do3xQB1QruGBv8bY=";
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
