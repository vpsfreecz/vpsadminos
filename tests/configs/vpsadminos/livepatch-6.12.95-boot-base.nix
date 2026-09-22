{
  config,
  lib,
  pkgs,
  ...
}:
let
  # These transition tests exercise the original livepatch ABI, not whatever
  # same-version kernel a later staging pin selects.
  mkKernel =
    zfsBuiltinPkg:
    pkgs.callPackage ../../../os/packages/linux {
      kernelVersion = "6.12.95";
      url = "https://github.com/vpsfreecz/linux/archive/a2384967b90f24d2470c9eb15f0e66d938df7e08.tar.gz";
      sha256 = "sha256-QlwV4uFeX7ZbWHMuU14rFXswmpqpb1hdVmYUAGOWRh8=";
      inherit zfsBuiltinPkg;
      # Preserve the original package declaration, including its unevaluated
      # merge marker. Normalizing it would change the historical ZFS config.
      features =
        if zfsBuiltinPkg == null then
          { }
        else
          lib.mkMerge [
            { }
            { zfsBuiltin = true; }
          ];
    };
  plainKernel = mkKernel null;
  zfsBuiltin =
    (pkgs.callPackage ../../../os/packages/zfs {
      configFile = "builtin";
      kernel = plainKernel;
      rev = "9f479d6551bebde664b71b6d7553e8d23c162c4c";
      sha256 = "sha256-arX7aWuTpmJ74YYtRgxh2MsA4ixC656GsDLcVWHhAZE=";
    }).zfsStable
      { enableDebug = config.system.vpsadminos.zfsDebug; };
in
{
  boot.kernelVersion = lib.mkForce "6.12.95";
  # The live-patches loader compares the module's configured kernel notes
  # (from the locked boot dev c7ckwabn…) against the running /sys/kernel/notes
  # and refuses on mismatch. A local rebuild of the .95 kernel carries
  # features = { zfsBuiltin } only, so enableBuildId is false and its .notes
  # cannot equal the boot kernel's. Boot the exact boot kernel objects instead
  # by wrapping the plain package with the boot out/dev/config paths (A8(b)
  # shape); modDirVersion and the remaining attributes stay from the evaluated
  # package.
  boot.kernelPackage = lib.mkForce (
    plainKernel
    // {
      outPath = builtins.storePath "/nix/store/f3rgj3iq8z1kvkc0g64d4mgyrjhi0q6w-linux-6.12.95";
      dev = builtins.storePath "/nix/store/c7ckwabnv0k4yfys5jnswjz08ffmirwh-linux-6.12.95-dev";
      configfile = {
        outPath = builtins.storePath "/nix/store/np082gl8insab5lisjdhqlh4128jlm9m-linux-config-6.12.95";
      };
    }
  );
  # A25c: no zfsBuiltin/zfsBuiltinPkg override here — the OS default must apply
  # so that system.build.livePatches re-evaluates to the verified
  # 76qfpsyj…-livepatch_7-6.12.95.drv. kernelForBuiltinsConfig stays consistent
  # with the pinned boot kernel.
  boot.kernelForBuiltinsConfig = lib.mkForce (
    plainKernel
    // {
      outPath = builtins.storePath "/nix/store/f3rgj3iq8z1kvkc0g64d4mgyrjhi0q6w-linux-6.12.95";
      dev = builtins.storePath "/nix/store/c7ckwabnv0k4yfys5jnswjz08ffmirwh-linux-6.12.95-dev";
      configfile = {
        outPath = builtins.storePath "/nix/store/np082gl8insab5lisjdhqlh4128jlm9m-linux-config-6.12.95";
      };
    }
  );
}
