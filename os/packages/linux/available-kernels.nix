{ lib }:
with lib.kernel;
{
  stableKernelVersion = "6.12.109";
  unstableKernelVersion = "6.12.109";

  kernels = {
    "6.12.109" = {
      rev = "7c66ab3c284a5fb5b615f874a99cb16501d6de23";
      sha256 = "sha256-/PiHSS9A1oYWg95k1e1yzjKgbClehMtUSh1LyvsDsTA=";
      features.livepatchVariant = "nfs-cancel";
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
