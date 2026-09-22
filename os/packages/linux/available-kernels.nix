{ lib }:
with lib.kernel;
{
  stableKernelVersion = "6.12.109";
  unstableKernelVersion = "6.12.109";

  kernels = {
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
