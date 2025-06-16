{ lib, version ? null, ... }:
with lib;

let

  availablePatches = [
    { name = "bp-6.12.33-cumulative";
      filterFn = availableFor "6.12.33";
      version = 1;
    }
    { name = "bp-6.9.12-2-cumulative";
      filterFn = availableFor "6.9.12-2";
      version = 1;
    }
    { name = "bp-6.12.14-cumulative";
      filterFn = availableFor "6.12.14";
      version = 1;
    }
    { name = "bp-6.12.18-cumulative";
      filterFn = availableFor "6.12.18";
      version = 1;
    }
    { name = "bp-6.12.29-cumulative";
      filterFn = availableFor "6.12.29";
      version = 1;
    }
    { name = "bp-6.11.8-cumulative";
      filterFn = availableFor "6.11.8";
      version = 2;
    }
    { name = "bp-6.10.10-cumulative";
      filterFn = availableFor "6.10.10";
      version = 1;
    }
    { name = "bp-6.8.8-2-cumulative";
      filterFn = availableFor "6.8.8-2";
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
