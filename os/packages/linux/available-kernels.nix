{ lib }:
with lib.kernel;
{
  stableKernelVersion = "6.12.95";
  unstableKernelVersion = "6.18.49";

  kernels = {
    "6.18.49" = {
      rev = "37bf4b6e9347d916997b9e76f5204cd06c2da8d0";
      sha256 = "sha256-1IdwQ1AM1YZDP5MlehrELJ8/LZlSS0eTnDQKHchOyhs=";
      features.livepatchVariant = "nfs-cancel";
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
        rev = "4ded9ca89108e507377ff3d613038bea16018b2d";
        sha256 = "sha256-WtnAKH7j4N7nN1NRCF1Ky5wDwjFQynfuRZyvVqn2VWs=";
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
    "6.12.95" = {
      rev = "a2384967b90f24d2470c9eb15f0e66d938df7e08";
      sha256 = "sha256-QlwV4uFeX7ZbWHMuU14rFXswmpqpb1hdVmYUAGOWRh8=";
      zfs = {
        rev = "9f479d6551bebde664b71b6d7553e8d23c162c4c";
        sha256 = "sha256-arX7aWuTpmJ74YYtRgxh2MsA4ixC656GsDLcVWHhAZE=";
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
