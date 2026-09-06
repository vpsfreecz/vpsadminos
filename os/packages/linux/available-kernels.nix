{ lib }:
with lib.kernel;
{
  stableKernelVersion = "6.12.109";
  unstableKernelVersion = "6.18.49";

  kernels = {
    "6.18.49" = {
      rev = "a770f5086fc500ca258852aea1cb3e209a342d2b";
      # Linux uses fetchurl: hash archive bytes, not the unpacked source tree.
      sha256 = "sha256-YJVRl+2+x+arnS3vzteI+t8LRUKAKDlONCrw9bbmZK0=";
      structuredExtraConfig = {
        DAMON = yes;
        DAMON_VADDR = yes;
        DAMON_PADDR = yes;
        DAMON_SYSFS = yes;
        DAMON_RECLAIM = yes;
        PSI = no;
        SCHED_CLASS_EXT = no;
        SCHED_PROXY_EXEC = yes;
        TRACING_NS = yes;
      };
      zfs = {
        rev = "60536e063336cb5daaec84637297f738a399c44c";
        sha256 = "sha256-hZobxKP9MIVOFRVueXG7oTGTiPJVIp9d+J3HRNJKUsw=";
      };
    };
    "6.18.44" = {
      rev = "15f0cb69214054627f1d2b1c0d14556c15a1ace3";
      sha256 = "sha256-/dXTySrZXulvADPPDzfV7H9xIFvyDboLTF6SLI6OsE4=";
      structuredExtraConfig = {
        DAMON = yes;
        DAMON_VADDR = yes;
        DAMON_PADDR = yes;
        DAMON_SYSFS = yes;
        DAMON_RECLAIM = yes;
        PSI = no;
        SCHED_CLASS_EXT = no;
        SCHED_PROXY_EXEC = yes;
        TRACING_NS = yes;
      };
      zfs = {
        rev = "b2ade5816c3a16f779616c6d25710f7f2bca7ce9";
        sha256 = "sha256-OHzDCuQ9fP3qKPhA3QysBOwqzWiFUir6BcHv2hIONPg=";
      };
    };
    "6.12.109" = {
      rev = "9ccd5d6597a6ddbe5b44fb885ddf96e4dbc332dd";
      sha256 = "sha256-pkqWjsBfn3twbVFXP2Uk8FWvj8BJk9kTNCtSlyHZrCo=";
      zfs = {
        rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
        sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
      };
    };
    "6.12.95" = {
      rev = "563bbb35e8753e1bb34dad19ebeec8962ee3c1cd";
      sha256 = "sha256-7eve2Ljhkk+fozlWkN7k5SA0gtxDo3mbvQ0hIR3OVHs=";
      features.livepatchVariant = "nfs-cancel";
      zfs = {
        rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
        sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
      };
    };
    "6.12.48" = {
      rev = "5bbd15d9e42bca0ca4a8d102f5ea95cc71803e44";
      sha256 = "sha256-sJThPPzpW2gZinao9dLBpFokxwpsm3U4QxHvNk0S+GA=";
      zfs = {
        rev = "e0156ef58e8a113524efa45553e0321bf8c0f124";
        sha256 = "sha256-4Y73rsSguirDTHZHZATcMGeN3vWwlqEEWZOnBXJDNu8=";
      };
    };
  };
}
