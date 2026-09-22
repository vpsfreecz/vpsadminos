{ lib }:
with lib.kernel;
{
  stableKernelVersion = "6.12.109";
  unstableKernelVersion = "6.12.109";

  kernels = {
    # Final 6.12.110 boot candidate composed on the published Linux checkpoint.
    # The archive hash was realized from the guarded-published 248f8375 ref.
    # features.livepatch = true keeps the single-series 6.12.95 identity
    # contract: the boot kernel retains a content-derived GNU SHA1 build ID.
    "6.12.110" = {
      rev = "248f8375a5f7b30670828d2e1d8c88beeab76a20";
      sha256 = "sha256-ZzFMjaK+KBPorrjhcmulzrEJV6lCSVRsRo2JJbvLKnw=";
      features.livepatch = true;
      zfs = {
        rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
        sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
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
      rev = "a2384967b90f24d2470c9eb15f0e66d938df7e08";
      sha256 = "sha256-QlwV4uFeX7ZbWHMuU14rFXswmpqpb1hdVmYUAGOWRh8=";
      features.livepatch = true;
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
