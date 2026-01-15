testFn:
{
  configuration ?
    let
      cfg = builtins.getEnv "VPSADMINOS_CONFIG";
    in
    if cfg == "" then null else import cfg,
  pkgs ? <nixpkgs>,
  # extra modules to include
  modules ? [ ],
  # extra arguments to be passed to modules
  extraArgs ? { },
  # arguments passed to the test function
  testArgs ? null,
  testArgsInJson ? null,
  # target system
  system ? builtins.currentSystem,
}:
let
  nixpkgs = import pkgs {
    inherit system;
    config = { };
    overlays = [ (import ../os/overlays/packages.nix) ];
  };

  lib = nixpkgs.lib;
  nixosSystemFn = import (nixpkgs.path + "/nixos/lib/eval-config.nix");
  qemuPackage = nixpkgs.pkgs.qemu_kvm.override {
    hostCpuOnly = true;
    nixosTestRunner = true;
  };
  virtiofsdPackage = nixpkgs.pkgs.virtiofsd;
  defaultNetworks = [ { type = "user"; } ];

  effectiveTestArgs =
    if !(isNull testArgs) then
      testArgs
    else if !(isNull testArgsInJson) then
      builtins.fromJSON testArgsInJson
    else
      { };

  testAttrs = testFn ({ pkgs = nixpkgs; } // effectiveTestArgs);

  vpsadminosSystem =
    cfg:
    import ../os {
      inherit
        configuration
        pkgs
        extraArgs
        system
        ;
      modules = modules ++ (cfg.modules or [ ]) ++ [ cfg.config or { } ];
    };

  nixosSystem =
    name: machine:
    nixosSystemFn {
      inherit system;
      specialArgs = extraArgs;
      modules =
        modules
        ++ [ (nixpkgs.path + "/nixos/modules/virtualisation/qemu-vm.nix") ]
        ++ (machine.modules or [ ])
        ++ [ ./nixos/configs/base.nix ]
        ++ [ machine.config or { } ];
    };

  machineAttrs =
    if lib.hasAttr "machine" testAttrs then
      { machine = testAttrs.machine; }
    else if lib.hasAttr "machines" testAttrs then
      testAttrs.machines
    else
      { machine = { }; };

  machineTestConfig =
    name: machine:
    let
      spin = machine.spin or "vpsadminos";
    in
    if spin == "nixos" then
      nixosMachineTestConfig name machine (nixosSystem name machine)
    else if spin == "vpsadminos" then
      vpsadminosMachineTestConfig machine (vpsadminosSystem machine)
    else
      builtins.throw "Unsupported machine spin '${spin}', expected 'nixos' or 'vpsadminos'";

  vpsadminosMachineTestConfig =
    machine: vpsadminos:
    let
      qemuCfg = vpsadminos.config.boot.qemu;
    in
    {
      spin = "vpsadminos";
      qemu = toString qemuPackage;
      virtiofsd = toString virtiofsdPackage;
      memory = qemuCfg.memory;
      cpus = qemuCfg.cpus;
      cpu = qemuCfg.cpu;
      disks = machine.disks or [ ];
      networks = machine.networks or defaultNetworks;
      sharedFileSystems = machine.sharedFileSystems or { };
      squashfs = vpsadminos.config.system.build.squashfs;
      kernel = "${vpsadminos.config.system.build.kernel}/bzImage";
      initrd = "${vpsadminos.config.system.build.initialRamdisk}/initrd";
      toplevel = vpsadminos.config.system.build.toplevel;
      kernelParams =
        vpsadminos.config.boot.kernelParams
        ++ [
          "quiet"
          "panic=-1"
        ]
        ++ (machine.kernelParams or [ ]);
      extraQemuOptions = machine.extraQemuOptions or qemuCfg.extraQemuOptions or [ ];
    };

  nixosMachineTestConfig =
    name: machine: nixos:
    let
      fsType = machine.fsType or "ext4";
      diskLabel = machine.diskLabel or "nixos";
      cpuCfg =
        machine.cpu or {
          cores = machine.cores or nixos.config.virtualisation.cores;
          threads = machine.threads or 1;
          sockets = machine.sockets or 1;
        };
      cpus = if machine ? cpus then machine.cpus else cpuCfg.cores * cpuCfg.threads * cpuCfg.sockets;
      diskImageBase = "nixos-test-${testAttrs.name}-${name}";
      diskImage = import "${nixpkgs.path}/nixos/lib/make-disk-image.nix" {
        pkgs = nixpkgs;
        lib = nixpkgs.lib;
        config = nixos.config;
        format = "raw";
        partitionTableType = "none";
        installBootLoader = false;
        baseName = diskImageBase;
        name = "nixos-${testAttrs.name}-${name}-disk-image";
        label = diskLabel;
        fsType = fsType;
        diskSize = machine.diskSize or "auto";
        additionalSpace = machine.additionalSpace or "512M";
        memSize = nixos.config.virtualisation.memorySize;
        copyChannel = false;
      };
      diskImagePath = "${diskImage}/${diskImageBase}.img";
    in
    {
      spin = "nixos";
      qemu = toString qemuPackage;
      virtiofsd = toString virtiofsdPackage;
      memory = machine.memory or nixos.config.virtualisation.memorySize;
      cpus = cpus;
      cpu = cpuCfg;
      diskImage = diskImagePath;
      disks = machine.disks or [ ];
      networks = machine.networks or defaultNetworks;
      sharedFileSystems = machine.sharedFileSystems or { };
      kernel = "${nixos.config.system.build.kernel}/bzImage";
      initrd = "${nixos.config.system.build.initialRamdisk}/initrd";
      toplevel = nixos.config.system.build.toplevel;
      kernelParams =
        nixos.config.boot.kernelParams
        ++ [
          "panic=-1"
          "root=/dev/disk/by-label/${diskLabel}"
          "rootfstype=${fsType}"
        ]
        ++ (machine.kernelParams or [ ]);
      extraQemuOptions = machine.extraQemuOptions or [ ];
    };

  machineTestConfigs = lib.mapAttrs machineTestConfig machineAttrs;

  testScripts =
    testAttrs.testScripts or {
      default = {
        script = testAttrs.testScript;
        tags = [ ];
        labels = { };
      };
    };

  testConfig = {
    inherit (testAttrs) name description;
    expectFailure = testAttrs.expectFailure or false;
    attempts = testAttrs.attempts or 1;
    machines = machineTestConfigs;
    tags = testAttrs.tags or [ ];
    labels = testAttrs.labels or { };
    inherit testScripts;
  };

  jsonConfig = nixpkgs.pkgs.writeText "os-test-${testAttrs.name}.json" (builtins.toJSON testConfig);
in
{
  config = testConfig;
  json = jsonConfig;
}
