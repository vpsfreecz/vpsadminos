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
      rev = "c099b00eafe7ced993eb6a7166876bb12bef8c72";
      sha256 = "sha256-SYqViJCugtDarN9JFdLBj4K2fMqbx+JykdLlGK0biZ8=";
      zfs = {
        rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
        sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
      };
    };
    "6.12.95" = {
      rev = "e232e2bdcc9a552b60b49ab8994bd49b115e1e58";
      sha256 = "sha256-4HdPnxHLB5UlhkeFz6upt++NPOf5zXQu0xHEPQZpGv0=";
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
