{ lib }:
with lib.kernel;
{
  stableKernelVersion = "6.12.95";
  unstableKernelVersion = "6.12.95";

  kernels = {
    "6.12.95" = {
      rev = "563bbb35e8753e1bb34dad19ebeec8962ee3c1cd";
      sha256 = "sha256-7eve2Ljhkk+fozlWkN7k5SA0gtxDo3mbvQ0hIR3OVHs=";
      features.livepatchVariant = "nfs-cancel";
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
