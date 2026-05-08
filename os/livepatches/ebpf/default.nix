# os/livepatches/ebpf/default.nix - eBPF livepatch package for vpsAdminOS
#
# This is a convenience re-export. The primary build logic lives in
# os/packages/ebpf-livepatch/default.nix.
#
# BPF programs live in os/livepatches/ebpf/programs/ as .bpf.c source files.
# Add new programs there and register them in the programs attrset below.
#
# Usage from a NixOS/vpsAdminOS module:
#   ebpf = pkgs.callPackage ../../os/livepatches/ebpf {
#     inherit (config.boot) kernelPackage;
#   };
#   ebpf.loader  # the loader binary
#   ebpf.bpfObjs # attribute set of compiled .bpf.o files

{
  pkgs ? import <nixpkgs> {},
  kernel ? null,
}:

assert kernel != null;

pkgs.callPackage ../../packages/ebpf-livepatch {
  inherit kernel;
  bpftool = pkgs.bpftools;
  libbpf = pkgs.libbpf;
  elfutils = pkgs.elfutils;
  zlib = pkgs.zlib;
}
