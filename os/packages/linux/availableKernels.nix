{ pkgs, ... }:
let
  defaultKernelVersion = "5.10.98";
  kernels = {
    "5.10.98" = {
      url = linuxGhUrl vpsfGh "c0533a6a6b4af2f37863ad1626edaced4dc4edc6";
      sha256 = "sha256-EqoVOFT/CxIV4zd2eOCM78TBBjUYU7Jrj+86yOwaK0A=";
      zfs = {
        rev = "cf79c5d7e3185db69f41452e3ebbe0576a8c5dd5";
        sha256 = "sha256-HLizndgrsOboRkIlmCfEfGFwoXweamkkddKdnQxSWWU=";
      };
    };

    "5.10.93" = {
      url = linuxGhUrl vpsfGh "5b4d755822c636c4cd51a0fd9d795feb4844c140";
      sha256 = "0c2zxxf6m3p6nn26daxckp3rjambs29j9va8fhps8ll5pr6fnd1p";
      zfs = {
        rev = "1dec83e455dffb573ad8e55cca5373d9bd5b756f";
        sha256 = "sha256:05rj2qxg0zyqagdqln2gd5c6a1dfqwnkv1dlhhfyy6x34xhsdd5r";
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
