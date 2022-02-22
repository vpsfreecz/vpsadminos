{ lib, version ? null, ... }:
with lib;

let

  availablePatches = [
    { name = "uname";
      filterFn = availableForAllKernels;
      version = 2;
    }
    { name = "ucounts-overlimit-fix";
      filterFn = availableForRange "5.10.93" "5.10.98";
    }
    { name = "bp-5.10.101-nfs-fixes";
      filterFn = availableFor "5.10.98";
    }
    { name = "nfs-unfreezer-workaround";
      filterFn = availableSince "5.10.93";
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
