{ lib, version ? null, ... }:
with lib;

let

  availablePatches = [
    { name = "bp-6.6.17-cumulative";
      filterFn = availableFor "6.6.17";
      version = 1;
    }
    { name = "bp-6.6.13-cumulative";
      filterFn = availableFor "6.6.13";
      version = 1;
    }
    { name = "bp-6.6.10-cumulative";
      filterFn = availableFor "6.6.10";
      version = 1;
    }
  ];

  availableForAllKernels = kernelVersion: true;
  availableFor = compatVersion: kernelVersion:
    kernelVersion == compatVersion;
  availableSince = verLow: kernelVersion:
    (versionAtLeast kernelVersion verLow);
  availableForRange = verLow: verHigh: kernelVersion:
    (versionAtLeast kernelVersion verLow && versionUpTo kernelVersion verHigh);
  versionUpTo = v1: v2: builtins.compareVersions v2 v1 < 1;

  getPatchVersion = patch: if (hasAttr "version" patch) then patch.version else 1;
  filterPatches = kernelVersion: filter (patch: patch.filterFn kernelVersion) availablePatches;
  filterPatchesVersions = kernelVersion: map getPatchVersion (filterPatches kernelVersion);
  filterPatchesVersionsSum = kernelVersion: foldl (x: y: x+y) 0 (filterPatchesVersions kernelVersion);

  patchListForVersion = kernelVersion: map (patch: patch.name) (filterPatches kernelVersion);
in {
  getPatchVersion = getPatchVersion;
  patchList  = patchListForVersion version;
  patchVersion = filterPatchesVersionsSum version;
  filteredPatches = filterPatches version;
  allPatches = availablePatches;
}
