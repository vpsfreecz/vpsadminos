{ lib }:
with lib.kernel;
rec {
  stableKernelVersion = "6.12.109";
  unstableKernelVersion = "6.12.109";

  nfsCancellationKernelVersions = lib.attrNames (
    lib.filterAttrs (_: kernel: kernel.nfsCancellation or false) kernels
  );

  kernels = {
    "6.12.109" = {
      nfsCancellation = true;
      rev = "cb16974b66f518b920226285b50f0b1f4416852e";
      sha256 = "sha256-30tXA0sDKbJfIbAdYIi8iE10uU51XfcgpxHQ4o2hgag=";
      zfs = {
        rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
        sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
      };
    };
    "6.12.95" = {
      rev = "6090ca00cbec50ca2a4ad785de361eaeaf1db529";
      sha256 = "sha256-rvLGBGPa0GyDOpN5jnQ4Rle/CujZNxZrg09fub+bot8=";
      features.livepatchVariant = "nfs-cancel";
      nfsCancellation = true;
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
