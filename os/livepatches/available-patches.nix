{
  lib,
  version ? null,
  ...
}:
with lib;

let

  ownedPatches = (import ./owned-records.nix { inherit lib; }) ./legacy "[A-Za-z0-9][A-Za-z0-9_.-]*" (
    name: dir: files:
    let
      record = import dir { inherit availableForRange; };
    in
    assert lib.assertMsg (
      (files."${name}.patch" or null) == "regular"
    ) "Missing owned livepatch source ${name}.patch";
    record
    // {
      inherit name;
      source = dir + "/${name}.patch";
    }
  );

  availablePatches = builtins.attrValues ownedPatches ++ [
    # The uname patch is the canonical livepatch example.
    # It changes init_uts_ns.name.release to "<kernelVer>.<patchVer>"
    # so that `uname -r` shows the livepatch is active.
    # Uncomment to enable:
    # {
    #   name = "uname";
    #   filterFn = availableForAllKernels;
    # }
  ];

  availableForAllKernels = kernelVersion: true;
  availableFor = compatVersion: kernelVersion: kernelVersion == compatVersion;
  availableSince = verLow: kernelVersion: (versionAtLeast kernelVersion verLow);
  availableForRange =
    verLow: verHigh: kernelVersion:
    (versionAtLeast kernelVersion verLow && versionUpTo kernelVersion verHigh);
  versionUpTo = v1: v2: builtins.compareVersions v1 v2 < 1;

  getPatchVersion = patch: if (hasAttr "version" patch) then patch.version else 1;
  filterPatches = kernelVersion: filter (patch: patch.filterFn kernelVersion) availablePatches;
  filterPatchesVersions = kernelVersion: map getPatchVersion (filterPatches kernelVersion);
  filterPatchesVersionsSum =
    kernelVersion: foldl (x: y: x + y) 0 (filterPatchesVersions kernelVersion);

  patchListForVersion =
    kernelVersion:
    concatMap (patch: patch.buildPatches or [ patch.name ]) (filterPatches kernelVersion);
  patchTargetsForVersion =
    kernelVersion: unique (concatMap (patch: patch.targets or [ ]) (filterPatches kernelVersion));
in
{
  getPatchVersion = getPatchVersion;
  patchList = patchListForVersion version;
  patchTargets = patchTargetsForVersion version;
  patchSources = map (name: ownedPatches.${name}.source or (./. + "/${name}.patch")) (
    patchListForVersion version
  );
  inherit ownedPatches;
  patchVersion = filterPatchesVersionsSum version;
  filteredPatches = filterPatches version;
  allPatches = availablePatches;
}
