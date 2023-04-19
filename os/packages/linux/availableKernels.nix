{ pkgs, ... }:
let
  defaultKernelVersion = "5.10.179";
  kernels = {
    "6.1.30" = {
      url = linuxGhUrl vpsfGh "88f1ad6a35e28aaa5a2af112e35fabea21207fb8";
      sha256 = "sha256-7dMqLXzLnQotwKXMf+t4bthuo/q5QzrzZpfgxKACNoQ=";
      zfs = {
        rev = "ecaf4ac63b5fdce28cf135a42f4a00589bc80af5";
        sha256 = "sha256-xm1ShlbpcWADlUF71rzVrK9sbrspt1KzHksXm4L6CD4=";
      };
    };
    "5.10.179" = {
      url = linuxGhUrl vpsfGh "e58bd2f549191933eb3ba174cfd29041e3318867";
      sha256 = "sha256-ZJgkQibM87n7Yj50Q2fa7LCFOf1gvLOYsdPNEliAN+4=";
      zfs = {
        rev = "0f62dafd70297dd1ba4069fc2305a792e314c7f9";
        sha256 = "sha256-ewqBPaQCl4qXL7au26pWtv5jea2ixlpwLIY2fI21vyk=";
      };
    };
    "5.10.164" = {
      url = linuxGhUrl vpsfGh "19f98e2800614c7918a14e06fa9554dbf046a933";
      sha256 = "sha256-pvO5jogooS6QeQ6pz9sAXQWgVt8D4r6fcHp5RxJTVKU=";
      zfs = {
        rev = "e40513b5ae9e5d8cdfac4463cbdcc526c3878553";
        sha256 = "sha256-KNXXKP3T24mzsnEmbnXOrr+xTAZuHjvLpIoTMNrL7G8=";
      };
    };
    "5.10.159" = {
      url = linuxGhUrl vpsfGh "c0bac5c63223ac567d5549f785967c4d617dc4c3";
      sha256 = "sha256-YgQY+KB0a15OEc43w4LBQkFHmkGm5c7oFPvBlhpde8c=";
      zfs = {
        rev = "e40513b5ae9e5d8cdfac4463cbdcc526c3878553";
        sha256 = "sha256-KNXXKP3T24mzsnEmbnXOrr+xTAZuHjvLpIoTMNrL7G8=";
      };
    };
    "5.10.157" = {
      url = linuxGhUrl vpsfGh "c4169e6f02b7cc34d313f2aab07ccafb42ca93b4";
      sha256 = "sha256-9vmQq96eMe3vH2pO+MLZxk3B/wqB+1Bg/K5BcacKCk0=";
      zfs = {
        rev = "e40513b5ae9e5d8cdfac4463cbdcc526c3878553";
        sha256 = "sha256-KNXXKP3T24mzsnEmbnXOrr+xTAZuHjvLpIoTMNrL7G8=";
      };
    };
    "5.10.155" = {
      url = linuxGhUrl vpsfGh "9109fd2ada4e344f9d773b949dfc590a654e447c";
      sha256 = "sha256-Pn8x5q0mbQoI0SzjZBv/n/NXnNeZ/33gg4K06duLKWE=";
      zfs = {
        rev = "53611a4a5f02c0a178af62033d52cd8f0b7a5518";
        sha256 = "sha256-WlhDS0Ekz8fSERys8rWgurbq6VICztsGbskIbhvzTGc=";
      };
    };
    "5.10.154" = {
      url = linuxGhUrl vpsfGh "d89a633f62d49e98fed493d0019ccc8898e01571";
      sha256 = "sha256-hxqXTgLeb7HG/1TuudPMnSV5QNDk56yEnq2iq7OWJLA=";
      zfs = {
        rev = "d306a1cd3fee5261b0ebdcc0e2dd9b405db2bd97";
        sha256 = "sha256-rdTeAK/kqFn0NsDAom0QVyaJGkuqGVpSXz3AubIVKYk=";
      };
    };
    "5.10.153" = {
      url = linuxGhUrl vpsfGh "b9afc222c8cd957b7672792e9af4df814009ca56";
      sha256 = "sha256-MVKyIRhLihYd8FL9JvEo0fRlk+VX8Zda4ynFiNej4BM=";
      zfs = {
        rev = "d306a1cd3fee5261b0ebdcc0e2dd9b405db2bd97";
        sha256 = "sha256-rdTeAK/kqFn0NsDAom0QVyaJGkuqGVpSXz3AubIVKYk=";
      };
    };
    "5.10.149" = {
      url = linuxGhUrl vpsfGh "8c892745efb5f56c84a5d9503bc42a41dc836915";
      sha256 = "sha256-i86a7xPY7luE7vU9C3X63dZaS/RU9TTQOipCfk6nk3w=";
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
