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
          Enable eBPF-based live patching of kernel behavior.
          Loads BPF programs that can override syscalls, block operations
          via LSM hooks, or otherwise modify kernel behavior at runtime
          without rebooting.

          This is a proof-of-concept module for vpsAdminOS.
        '';
      };

      programs = mkOption {
        type = types.attrsOf types.attrs;
        default = {
          override_uname = { };
          lsm_example = { };
        };
        description = ''
          BPF programs to load. Keys are program names matching
          .bpf.c files in os/ebpf/programs/. Values are per-program
          configuration (reserved for future use).
        '';
      };

      autoLoad = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Automatically load BPF programs via runit service at boot.
          When disabled, the ebpf-livepatch-loader binary is still
          available in the system path for manual use.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ ebpfPkg.loader ];

    environment.etc."ebpf-livepatch" = {
      text = ''
        EBPF_LOADER=${ebpfPkg.loader}/bin/ebpf-loader
        EBPF_BPF_DIR=${ebpfPkg.loader}/bpf
        EBPF_PROGRAMS=${concatStringsSep " " (attrNames cfg.programs)}
      '';
    };

    runit.services.ebpf-livepatch = mkIf cfg.autoLoad {
      run = ''
        echo "ebpf-livepatch: loading BPF programs..."
        ${ebpfPkg.loader}/bin/ebpf-loader run all || echo "ebpf-livepatch: some programs failed to load"
        echo "ebpf-livepatch: programs loaded, keeping service alive"
        sleep inf
      '';
      finish = ''
        echo "ebpf-livepatch: unloading BPF programs..."
        echo "ebpf-livepatch: programs detached (on process exit)"
      '';
      runlevels = [ "default" ];
      onChange = "restart";
    };
  };
}
