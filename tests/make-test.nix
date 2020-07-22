testFn:
{ configuration ? let cfg = builtins.getEnv "VPSADMINOS_CONFIG"; in if cfg == "" then null else import cfg
, pkgs ? <nixpkgs>
  # extra modules to include
, modules ? []
  # extra arguments to be passed to modules
, extraArgs ? {}
  # target system
, system ? builtins.currentSystem
, vpsadmin ? null }:
let
  nixpkgs = import pkgs { inherit system; config = {}; };

  lib = nixpkgs.lib;

  testAttrs = testFn nixpkgs;

  machineOs = cfg: import ../os {
    inherit configuration pkgs extraArgs system vpsadmin;
    modules = modules ++ [ cfg ];
  };

  machineAttrs =
    if lib.hasAttr "machine" testAttrs then
      { machine = testAttrs.machine; }
    else if lib.hasAttr "machines" testAttrs then
      testAttrs.machines
    else { machine = {}; };

  machineTestConfig = machineAttrs: os:
    let
      qemuCfg = os.config.boot.qemu;
    in {
      qemu = toString nixpkgs.pkgs.qemu_kvm;
      memory = qemuCfg.memory;
      cpus = qemuCfg.cpus;
      cpu = qemuCfg.cpu;
      disks = machineAttrs.disks or [];
      squashfs = os.config.system.build.squashfs;
      kernel = "${os.config.system.build.kernel}/bzImage";
      initrd = "${os.config.system.build.initialRamdisk}/initrd";
      toplevel = os.config.system.build.toplevel;
      kernelParams = os.config.boot.kernelParams ++ [ "quiet" "panic=-1" ];
    };

  machineTestConfigs = lib.mapAttrs (name: machine:
    machineTestConfig machine (machineOs machine.config)
  ) machineAttrs;

  testConfig = {
    inherit (testAttrs) name description testScript;
    machines = machineTestConfigs;
  };

  jsonConfig = nixpkgs.pkgs.writeText "os-test-${testAttrs.name}.json" (builtins.toJSON testConfig);
in {
  config = testConfig;
  json = jsonConfig;
}
