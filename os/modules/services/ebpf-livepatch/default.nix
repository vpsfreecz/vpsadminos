{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.services.ebpf-livepatch;
  kernel = config.boot.kernelPackage;
  kernelVersion = config.boot.kernelVersion;

  ebpfDir = ../../../livepatches/ebpf;
  available = import (ebpfDir + /available.nix) {
    inherit lib kernelVersion;
  };

  programsEnabled = available.programs';

  requestedProgramNames = attrNames cfg.programs;
  unknownProgramNames = filter (name: !(hasAttr name available.programsByName)) requestedProgramNames;
  unavailableProgramNames = filter (
    name:
    hasAttr name available.programsByName && !(available.programAvailableForKernel kernelVersion name)
  ) requestedProgramNames;
  invalidProgramBpfNames = filter (
    name:
    hasAttr name available.programsByName
    && !(available.programHasValidBpfPrograms available.programsByName.${name})
  ) requestedProgramNames;

  programKernelRange =
    program:
    "kernel >= ${program.sinceKernel} (inclusive)"
    + optionalString (program ? untilKernel) " and <= ${program.untilKernel} (inclusive)";

  unavailableProgramDescription =
    name: "${name} (${programKernelRange available.programsByName.${name}})";

  ebpfPkg = pkgs.callPackage ../../../packages/ebpf-livepatch {
    inherit kernel;
    inherit (pkgs) libbpf elfutils zlib;
    bpftool = pkgs.bpftools;
    programs = cfg.programs;
  };

  programMetadata = map (
    name:
    let
      program = available.programsByName.${name};
    in
    {
      inherit name;
      description = program.description;
      sinceKernel = program.sinceKernel;
      untilKernel = program.untilKernel or null;
      bpfPrograms = program.bpfPrograms;
    }
  ) (filter (name: hasAttr name available.programsByName) requestedProgramNames);
in
{
  options = {
    services.ebpf-livepatch = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable eBPF-based live patching of kernel behavior at runtime.

          Loads BPF programs that can override syscalls, block operations
          via LSM hooks, or otherwise modify kernel behavior without rebooting.

          Only programs listed in os/livepatches/ebpf/available.nix are
          compiled and loaded. This is a proof-of-concept for vpsAdminOS.
        '';
      };

      programs = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = { };
          }
        );
        default = programsEnabled;
        description = ''
          eBPF programs to load, keyed by program name.

          Defaults to the complete list from available.nix filtered
          by kernel version requirements. In the program registry, sinceKernel
          is an inclusive lower bound and untilKernel is an inclusive upper
          bound when set. Programs can be selected only when the current
          boot.kernelVersion is within those bounds.
        '';
      };

      autoLoad = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Automatically load eBPF programs via runit service at boot.
          When disabled, the ebpf-livepatch-loader binary is still
          available in the system path for manual use.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = unknownProgramNames == [ ];
          message =
            "services.ebpf-livepatch.programs contains unknown eBPF livepatch program(s): "
            + concatStringsSep ", " unknownProgramNames
            + ". Known programs: "
            + concatStringsSep ", " available.allProgramNames;
        }
        {
          assertion = unavailableProgramNames == [ ];
          message =
            "services.ebpf-livepatch.programs contains eBPF livepatch program(s) "
            + "not available for kernel ${kernelVersion}: "
            + concatStringsSep ", " (map unavailableProgramDescription unavailableProgramNames);
        }
        {
          assertion = invalidProgramBpfNames == [ ];
          message =
            "services.ebpf-livepatch.programs contains eBPF livepatch program(s) "
            + "with invalid BPF program names: "
            + concatStringsSep ", " invalidProgramBpfNames
            + ". BPF program names must be non-empty and at most 15 characters.";
        }
      ];

      environment.etc."vpsadminos/ebpf-livepatch-monitor.json".text = builtins.toJSON {
        bpftool = "${pkgs.bpftools}/bin/bpftool";
        inherit kernelVersion;
        programs = programMetadata;
      };

      environment.systemPackages = [ ebpfPkg.loader ];
    }

    (mkIf cfg.autoLoad {
      runit.services.ebpf-livepatch = {
        run = ''
          echo "ebpf-livepatch: loading programs..."
          exec ${ebpfPkg.loader}/bin/ebpf-loader run all
        '';
        finish = ''
          echo "ebpf-livepatch: programs detached"
        '';
        runlevels = [ "default" ];
        onChange = "restart";
      };
    })
  ]);
}
