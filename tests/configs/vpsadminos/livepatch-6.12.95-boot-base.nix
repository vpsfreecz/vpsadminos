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
  # §265/§284/§285: the locked boot objects as a PLAIN store-path attrset — never
  # a derivation.  A `plainKernel // { outPath = …; }` merge keeps type/drvPath and
  # made Nix build and then hardlink INTO the locked path (Invalid cross-device
  # link, slave2 :1645 / §285).  Store-path refs only ⇒ nothing builds; the set
  # carries what the consumers read (${kernel}/bzImage, .dev, .modDirVersion,
  # root-shaped .modules, .override for kernel.nix:67).
  pinnedKernel = (builtins.removeAttrs plainKernel [ "drvPath" "type" "outputName" ]) // {
    outPath = builtins.storePath "/nix/store/f3rgj3iq8z1kvkc0g64d4mgyrjhi0q6w-linux-6.12.95";
    dev = builtins.storePath "/nix/store/c7ckwabnv0k4yfys5jnswjz08ffmirwh-linux-6.12.95-dev";
    configfile = { outPath = builtins.storePath "/nix/store/np082gl8insab5lisjdhqlh4128jlm9m-linux-config-6.12.95"; };
    modules = builtins.storePath "/nix/store/f3rgj3iq8z1kvkc0g64d4mgyrjhi0q6w-linux-6.12.95";
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
  # Boot the reviewed .95 kernel from its existing store paths. Keep the OS
  # defaults for kernelForBuiltinsConfig and builtin ZFS below.
  boot.kernelPackage = lib.mkForce pinnedKernel;
  # Do not override builtin-ZFS or kernelForBuiltinsConfig here: livePatches
  # must derive from the current OS payload and build inputs, not from a
  # historical module drv named by this boot fixture. Compare the evaluated
  # drv to the selected candidate separately from the pinned guest boot.
}
