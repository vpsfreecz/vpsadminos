{ pkgs, lib, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, kernelVersion, url, sha256, ... }:

with lib;

callPackage ./generic.nix ( rec {
  version = kernelVersion;

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = concatStrings (intersperse "." (take 3 (splitString "." "${version}.0")));

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    inherit url; inherit sha256;
  };
  kernelPatches = [ pkgs.kernelPatches.bridge_stp_helper ];
})
