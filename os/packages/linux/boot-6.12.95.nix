let
  # Livepatches must use the original boot ABI, not a same-version rebuild
  # with the current package set. Keep its immutable inputs buildable on
  # machines which do not already have the historical outputs in the store.
  source = builtins.getFlake "github:vpsfreecz/vpsadminos/c065fa2f8485399737e20e8ef9e44299d0766654";
  pkgs = import source.inputs.nixpkgs.outPath {
    system = "x86_64-linux";
    config = { };
    overlays =
      (import (source.outPath + "/os/overlays") {
        inherit (source.inputs) netlinkrb ruby-lxc;
      })
      ++ [
        # The historical kernel interpolates buildPackages.path when importing
        # kernel_config.nix. Preserve the existing store string throughout the
        # package set, including its nested callPackage calls. A path literal
        # would require copying Nixpkgs during read-only metadata evaluation.
        (_final: _prev: { path = source.inputs.nixpkgs.outPath; })
      ];
  };
  mkKernel =
    zfsBuiltinPkg:
    pkgs.callPackage (source.outPath + "/os/packages/linux") {
      kernelVersion = "6.12.95";
      url = "https://github.com/vpsfreecz/linux/archive/a2384967b90f24d2470c9eb15f0e66d938df7e08.tar.gz";
      sha256 = "sha256-QlwV4uFeX7ZbWHMuU14rFXswmpqpb1hdVmYUAGOWRh8=";
      inherit zfsBuiltinPkg;
      features = {
        livepatchVariant = "nfs-cancel";
      }
      // pkgs.lib.optionalAttrs (zfsBuiltinPkg != null) { zfsBuiltin = true; };
    };
  plainKernel = mkKernel null;
  zfs =
    (pkgs.callPackage (source.outPath + "/os/packages/zfs") {
      configFile = "builtin";
      kernel = plainKernel;
      rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
      sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
    }).zfsStable
      { enableDebug = false; };
  kernel = mkKernel zfs;
  toolchain = pkgs.stdenv.cc;
in
assert
  zfs.drvPath == "/nix/store/sp29nf66lg6slc9qkzbrjpz9r5gjywva-zfs-builtin-2.3-vpsadminos-6.12.95.drv";
assert kernel.drvPath == "/nix/store/rwffs5wf4jvigna0ykv85v93q1zkn8s5-linux-6.12.95.drv";
assert kernel.outPath == "/nix/store/f3rgj3iq8z1kvkc0g64d4mgyrjhi0q6w-linux-6.12.95";
assert kernel.dev.outPath == "/nix/store/c7ckwabnv0k4yfys5jnswjz08ffmirwh-linux-6.12.95-dev";
assert
  kernel.configfile.outPath == "/nix/store/np082gl8insab5lisjdhqlh4128jlm9m-linux-config-6.12.95";
assert toolchain.outPath == "/nix/store/hbsz2ngi9ixbhd9na1xagh2yc8qnmj7y-gcc-wrapper-15.2.0";
{
  inherit kernel toolchain;
}
