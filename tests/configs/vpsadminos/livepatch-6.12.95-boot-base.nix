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
  # §265: the locked boot kernel objects as a REAL derivation whose output is
  # the pinned files (hardlink farm) — a textual outPath patch cannot propagate
  # into the system closure (slave4 b407: coercion uses the derivation output).
  pinnedBoot = pkgs.runCommand "linux-6.12.95-boot-pinned" { } ''
    mkdir -p $out
    cp -al ${builtins.storePath "/nix/store/f3rgj3iq8z1kvkc0g64d4mgyrjhi0q6w-linux-6.12.95"}/. $out/
  '';
  pinnedKernel = plainKernel // {
    outPath = pinnedBoot.outPath;
    dev = builtins.storePath "/nix/store/c7ckwabnv0k4yfys5jnswjz08ffmirwh-linux-6.12.95-dev";
    configfile = {
      outPath = builtins.storePath "/nix/store/np082gl8insab5lisjdhqlh4128jlm9m-linux-config-6.12.95";
    };
    modules = pinnedBoot;
    # nixos kernel.nix calls kernel.override to inject randstructSeed; for the
    # pinned build the seed is already baked, so keep this kernel unchanged.
    override = _args: pinnedKernel;
  };
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
  # A8(b) + §265 variant A: pin the singular boot.kernelPackage; the OS set
  # (config/kernel.nix:36-37, origKernel = boot.kernelPackage) derives from it.
  boot.kernelPackage = lib.mkForce pinnedKernel;
  # A25c/A25d: no zfsBuiltin/zfsBuiltinPkg and no kernelForBuiltinsConfig
  # override here — the OS defaults must apply so that
  # system.build.livePatches re-evaluates to the verified
  # 76qfpsyj…-livepatch_7-6.12.95.drv (the fixture's zfs-builtin inputDrv must
  # stay 249agjkf…, built against the OS-default kernel). The machine itself
  # still boots the pinned boot kernelPackage above.
}
