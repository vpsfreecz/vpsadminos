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
  kernelVersionEnv = builtins.getEnv "VPSADMINOS_PROXY_EXEC_KERNEL_VERSION";
  linuxSource = /. + linuxSnapshot;
  linuxMakefile =
    if linuxSnapshot == "" then
      [ ]
    else
      lib.splitString "\n" (builtins.readFile (linuxSource + "/Makefile"));
  linuxMakeVariable =
    name:
    let
      line = lib.findFirst (line: lib.hasPrefix "${name} =" line) null linuxMakefile;
    in
    if line == null then
      throw "Linux snapshot Makefile does not define ${name}"
    else
      lib.removePrefix " " (lib.removePrefix "${name} =" line);
  snapshotKernelVersion =
    if linuxSnapshot == "" then
      null
    else
      "${linuxMakeVariable "VERSION"}.${linuxMakeVariable "PATCHLEVEL"}.${linuxMakeVariable "SUBLEVEL"}${linuxMakeVariable "EXTRAVERSION"}";
  snapshotKernelBranch =
    if snapshotKernelVersion == null then
      null
    else
      lib.concatStringsSep "." (lib.take 2 (lib.splitString "." snapshotKernelVersion));

  requestedKernelVersion =
    if kernelVersionEnv == "" then kernelPackages.defaultVersion else kernelVersionEnv;
  kernelVersion =
    if snapshotKernelVersion == null then
      requestedKernelVersion
    else if builtins.hasAttr snapshotKernelVersion kernelPackages.kernels then
      snapshotKernelVersion
    else if builtins.hasAttr snapshotKernelBranch kernelPackages.kernels then
      snapshotKernelBranch
    else
      throw "Linux snapshot ${snapshotKernelVersion} has no maintained kernel configuration";
  kernelDef = kernelPackages.kernels.${kernelVersion};

  baseStructuredExtraConfig =
    if builtins.hasAttr "structuredExtraConfig" kernelDef then kernelDef.structuredExtraConfig else { };

  proxyStructuredExtraConfig =
    baseStructuredExtraConfig
    // (with lib.kernel; {
      PSI = lib.mkForce no;
      SCHED_CLASS_EXT = lib.mkForce no;
      SCHED_PROXY_EXEC = yes;
      LOCK_TORTURE_TEST = lib.mkForce module;
    });

  kernelFeatures = if builtins.hasAttr "features" kernelDef then kernelDef.features else { };

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
        structuredExtraConfig = proxyStructuredExtraConfig;
        features = kernelFeatures;
        zfsBuiltinPkg = null;
      });

  pinnedKernel = pkgs.callPackage ../packages/linux {
    inherit kernelVersion;
    url = "https://github.com/vpsfreecz/linux/archive/${kernelDef.rev}.tar.gz";
    sha256 = kernelDef.sha256;
    structuredExtraConfig = proxyStructuredExtraConfig;
    features = kernelFeatures;
  };

  selectedKernel = if localKernel != null then localKernel else pinnedKernel;
in
{
  imports = [ ./local-dev-qemu.nix ];

  boot.kernelVersion = lib.mkIf (localKernelStage == "") (lib.mkForce selectedKernel.version);
  boot.kernelPackage = lib.mkIf (localKernelStage == "") (lib.mkForce selectedKernel);
  boot.zfsBuiltin = lib.mkForce false;

  boot.qemu.memory = lib.mkForce 3072;
  boot.qemu.cpus = lib.mkForce 4;
  boot.qemu.cpu.cores = lib.mkForce 4;
  boot.qemu.cpu.threads = lib.mkForce 1;
  boot.qemu.cpu.sockets = lib.mkForce 1;
}
