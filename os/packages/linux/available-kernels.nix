{ lib }:
with lib.kernel;
{
  stableKernelVersion = "6.12.95";
  unstableKernelVersion = "6.12.95";

  kernels = {
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
