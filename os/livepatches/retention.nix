# Offline maintenance inventory. Use the same predicates as deployment.
{ lib, kernelVersions }:
let
  legacy = import ./available-patches.nix { inherit lib; };
  ebpf = import ./ebpf/available.nix {
    inherit lib;
    kernelVersion = null;
  };
  batchCatalog = import ./batches { inherit lib; };
  packageOwners = import ../packages/linux/kernel-specific.nix { inherit lib; };
  assertOwner =
    version:
    lib.assertMsg (builtins.elem version kernelVersions) "Missing kernel payload owner ${version}";
  kernelOwners =
    map (unit: unit.batch.kernelVersion) batchCatalog ++ builtins.attrNames packageOwners;
in
assert builtins.all assertOwner kernelOwners;
assert builtins.deepSeq packageOwners true;
assert lib.assertMsg (
  lib.unique ebpf.allProgramNames == ebpf.allProgramNames
) "Duplicate eBPF program name";
{
  legacy = lib.mapAttrs (_: patch: builtins.filter patch.filterFn kernelVersions) legacy.ownedPatches;
  ebpf =
    lib.mapAttrs
      (_: program: builtins.filter (version: ebpf.programMatchesKernel version program) kernelVersions)
      (
        lib.filterAttrs (
          _: program: program.enable && builtins.all (range: range ? untilKernel) program.kernelRanges
        ) ebpf.ownedPrograms
      );
}
