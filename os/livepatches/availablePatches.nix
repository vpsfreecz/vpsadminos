{ lib, ... }:
with lib;

let

  patches = {
    "uname" = availableForAllKernels;
    "ucounts-overlimit-fix" = availableForRange "5.10.93" "5.10.98";
    "bp-5.10.101-nfs-fixes" = availableFor "5.10.98";
    "nfs-unfreezer-workaround" = availableSince "5.10.93";
  };

  availableForAllKernels = kernelVersion: true;
  availableFor = compatVersion: kernelVersion:
    kernelVersion == compatVersion;
  availableSince = verLow: kernelVersion:
    (versionAtLeast version verLow);
  availableForRange = verLow: verHigh: kernelVersion:
    (versionAtLeast version verLow && versionOlder version verHigh);

  filterPatches = kernelVersion: filterAttrs (n: filterFn: filterFn kernelVersion) patches;
in {
  allPatches = mapAttrsToList (n: v: n) patches;
  patchesForVersion = kernelVersion: mapAttrsToList (n: v: n) (filterPatches kernelVersion);
}
