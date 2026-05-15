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

  ebpfPkg = pkgs.callPackage ../../../packages/ebpf-livepatch {
    inherit kernel;
    inherit (pkgs) libbpf elfutils zlib;
    bpftool = pkgs.bpftools;
    programs = cfg.programs;
  };
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
        type = types.attrsOf types.attrs;
        default = programsEnabled;
        description = ''
          eBPF programs to load, keyed by program name.
          Defaults to the complete list from available.nix filtered
          by kernel version requirements.
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
