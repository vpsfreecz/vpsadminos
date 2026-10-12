{
  lib,
  pkgs,
  ...
}:
let
  bootKernel = (import ../../../os/packages/linux/boot-6.12.95.nix).kernel;

  # Keep the CURRENT OS package's build inputs for the v7 module. Only the
  # guest's exact boot outputs need the historical derivation dependency.
  currentPackageShape = pkgs.callPackage ../../../os/packages/linux {
    kernelVersion = "6.12.95";
    url = "https://github.com/vpsfreecz/linux/archive/a2384967b90f24d2470c9eb15f0e66d938df7e08.tar.gz";
    sha256 = "sha256-QlwV4uFeX7ZbWHMuU14rFXswmpqpb1hdVmYUAGOWRh8=";
    zfsBuiltinPkg = null;
    features = { };
  };
  # This remains an attrset, not a derivation whose output path was
  # overwritten. The exact historical output strings retain their Nix
  # derivation contexts so CI can build them from the immutable source.
  pinnedKernel =
    (builtins.removeAttrs currentPackageShape [
      "drvPath"
      "type"
      "outputName"
    ])
    // {
      outPath = bootKernel.outPath;
      dev = bootKernel.dev.outPath;
      configfile = {
        outPath = bootKernel.configfile.outPath;
      };
      modules = bootKernel.outPath;
      override = _args: pinnedKernel;
    };
in
{
  boot.kernelVersion = lib.mkForce "6.12.95";
  boot.kernelPackage = lib.mkForce pinnedKernel;
  # Keep the OS defaults for kernelForBuiltinsConfig and builtin ZFS; the
  # livepatch derivation must still come from the current OS payload.
}
