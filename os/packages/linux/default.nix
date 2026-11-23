{
  pkgs,
  lib,
  callPackage,
  buildPackages,
  stdenv,
  fetchurl,
  perl,
  buildLinux,
  elfutils,
  kernelVersion,
  url,
  sha256,
  features,
  structuredExtraConfig ? { },
  postConfigPatches ? [ ],
  zfsBuiltinPkg ? null,
  ...
}:

with lib;

callPackage ./generic.nix (rec {
  version = kernelVersion;

  inherit zfsBuiltinPkg;

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = concatStrings (intersperse "." (take 3 (splitString "." "${version}.0")));

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    inherit url;
    inherit sha256;
    # Give transient failures time to clear. Partial-transfer resumes can start
    # another curl retry window, so this is not a whole-fetch deadline.
    curlOptsList = [
      "--no-retry-all-errors"
      "--retry"
      "3"
      "--retry-delay"
      "30"
      "--connect-timeout"
      "30"
      "--max-time"
      "600"
      "--retry-max-time"
      "1800"
    ];
  };

  kernelPatches = [
    pkgs.kernelPatches.bridge_stp_helper
  ]
  ++ optional (kernelVersion == "6.12.109") {
    name = "nfs-sysfs-null-rpc-client";
    patch = ./nfs-sysfs-null-rpc-client-6.12.109.patch;
  }
  # GCC plugins use headers from the target compiler. Recheck the header on
  # the next 6.12 import; 6.12.118 is the last inspected downstream source.
  ++
    optional
      (
        versions.majorMinor kernelVersion == "6.12"
        && versionAtLeast "6.12.118" kernelVersion
        && stdenv.cc.isGNU
        && versionAtLeast stdenv.cc.version "16"
      )
      {
        name = "gcc-16-plugin-const-casts";
        patch = ./gcc-16-plugin-const-casts.patch;
      };

  inherit structuredExtraConfig postConfigPatches;

  inherit features;
  enableBuildId = (features.livepatch or null) != null;
})
