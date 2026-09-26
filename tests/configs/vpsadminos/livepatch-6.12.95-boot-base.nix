{
  lib,
  pkgs,
  ...
}:
let
  # Re-evaluate the reviewed boot line from its immutable GitHub revision.
  # This must reproduce the exact installed kernel and ZFS derivations; a
  # same-version rebuild using today's toolchain does not have the boot ABI.
  bootSource = builtins.getFlake "github:vpsfreecz/vpsadminos/c065fa2f8485399737e20e8ef9e44299d0766654";
  bootPkgs = import bootSource.inputs.nixpkgs.outPath {
    # The pinned boot image and its compiler/kernel notes are x86_64-only.
    system = "x86_64-linux";
    config = { };
    overlays = import (bootSource.outPath + "/os/overlays") {
      netlinkrb = bootSource.inputs.netlinkrb;
      ruby-lxc = bootSource.inputs.ruby-lxc;
    };
  };
  mkBootKernel =
    zfsInput:
    (bootPkgs.callPackage (bootSource.outPath + "/os/packages/linux") {
      kernelVersion = "6.12.95";
      url = "https://github.com/vpsfreecz/linux/archive/a2384967b90f24d2470c9eb15f0e66d938df7e08.tar.gz";
      sha256 = "sha256-QlwV4uFeX7ZbWHMuU14rFXswmpqpb1hdVmYUAGOWRh8=";
      zfsBuiltinPkg = zfsInput;
      features =
        if zfsInput == null then
          { livepatchVariant = "nfs-cancel"; }
        else
          {
            livepatchVariant = "nfs-cancel";
            zfsBuiltin = true;
          };
    });
  plainKernel = mkBootKernel null;
  bootZfs =
    (bootPkgs.callPackage (bootSource.outPath + "/os/packages/zfs") {
      configFile = "builtin";
      kernel = plainKernel;
      rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
      sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
    }).zfsStable
      { enableDebug = false; };
  bootKernel = mkBootKernel bootZfs;

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
assert
  bootZfs.drvPath
  == "/nix/store/sp29nf66lg6slc9qkzbrjpz9r5gjywva-zfs-builtin-2.3-vpsadminos-6.12.95.drv";
assert bootKernel.drvPath == "/nix/store/rwffs5wf4jvigna0ykv85v93q1zkn8s5-linux-6.12.95.drv";
assert bootKernel.outPath == "/nix/store/f3rgj3iq8z1kvkc0g64d4mgyrjhi0q6w-linux-6.12.95";
assert bootKernel.dev.outPath == "/nix/store/c7ckwabnv0k4yfys5jnswjz08ffmirwh-linux-6.12.95-dev";
assert
  bootKernel.configfile.outPath == "/nix/store/np082gl8insab5lisjdhqlh4128jlm9m-linux-config-6.12.95";
{
  boot.kernelVersion = lib.mkForce "6.12.95";
  boot.kernelPackage = lib.mkForce pinnedKernel;
  # Keep the OS defaults for kernelForBuiltinsConfig and builtin ZFS; the
  # livepatch derivation must still come from the current OS payload.
}
