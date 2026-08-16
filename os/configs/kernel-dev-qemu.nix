{
  config,
  pkgs,
  lib,
  ...
}:

let
  kernelPackages = import ../packages/linux/packages.nix {
    inherit config lib pkgs;
  };

  linuxSnapshot = builtins.getEnv "VPSADMINOS_LINUX_SNAPSHOT";
  localKernelStage = builtins.getEnv "VPSADMINOS_LOCAL_KERNEL_STAGE";
  linuxSource = /. + linuxSnapshot;
  linuxMakefile = lib.splitString "\n" (builtins.readFile (linuxSource + "/Makefile"));
  linuxMakeVariable =
    name:
    let
      line = lib.findFirst (line: lib.hasPrefix "${name} =" line) null linuxMakefile;
    in
    if line == null then
      throw "Linux snapshot Makefile does not define ${name}"
    else
      lib.removePrefix " " (lib.removePrefix "${name} =" line);
  snapshotKernelVersion = "${linuxMakeVariable "VERSION"}.${linuxMakeVariable "PATCHLEVEL"}.${linuxMakeVariable "SUBLEVEL"}${linuxMakeVariable "EXTRAVERSION"}";
  snapshotKernelBranch = lib.concatStringsSep "." (
    lib.take 2 (lib.splitString "." snapshotKernelVersion)
  );
  kernelVersion =
    if builtins.hasAttr snapshotKernelVersion kernelPackages.kernels then
      snapshotKernelVersion
    else if builtins.hasAttr snapshotKernelBranch kernelPackages.kernels then
      snapshotKernelBranch
    else
      kernelPackages.defaultVersion;
  kernelDef = kernelPackages.kernels.${kernelVersion};
  structuredExtraConfig = kernelDef.structuredExtraConfig or { };
  kernelFeatures = kernelDef.features or { };

  localKernel =
    if linuxSnapshot == "" then
      null
    else
      pkgs.callPackage ../packages/linux/generic.nix (rec {
        version = snapshotKernelVersion;
        modDirVersion = version;
        extraMeta.branch = lib.concatStringsSep "." (lib.take 2 (lib.splitString "." version));
        src = linuxSource;
        kernelPatches = [ pkgs.kernelPatches.bridge_stp_helper ];
        inherit structuredExtraConfig;
        features = kernelFeatures;
        zfsBuiltinPkg = null;
      });
in
{
  imports = [
    ./qemu.nix
    ./local-dev-qemu.nix
  ];

  boot.kernelVersion = lib.mkIf (localKernelStage == "") (
    lib.mkForce (if localKernel == null then kernelVersion else localKernel.version)
  );
  boot.kernelPackage = lib.mkIf (localKernelStage == "" && localKernel != null) (
    lib.mkForce localKernel
  );
  boot.zfsBuiltin = lib.mkForce false;
}
