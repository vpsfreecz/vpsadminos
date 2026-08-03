{ lib }:
with lib.kernel;
{
  stableKernelVersion = "6.12.95";
  unstableKernelVersion = "6.18.44";

  kernels = {
    "6.18.44" = {
      rev = "a230042fc2f292ced0d8d313633d8bcdd7d094c4";
      sha256 = "sha256-DYncAteUGqYFXmGYlsx8zedDuCWd5a0hFHbeagq6DQQ=";
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
        rev = "6f5f54c3bfd68c1e52b0b6f454ee9679aaa9e83d";
        sha256 = "sha256-4WQWL4wd3TYaTfqEqQ6ZDYLXmqnHW7XQz2DP0FpwsRQ=";
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
