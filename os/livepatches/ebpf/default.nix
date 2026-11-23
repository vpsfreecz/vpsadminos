# os/livepatches/ebpf/default.nix - eBPF livepatch package for vpsAdminOS
#
# This is a convenience re-export. The primary build logic lives in
# os/packages/ebpf-livepatch/default.nix.
#
# Deployable range programs live under owned/<name>/; examples live under
# programs/. See available.nix for discovery and target selection.
#
# Usage from a NixOS/vpsAdminOS module:
#   ebpf = pkgs.callPackage ../../os/livepatches/ebpf {
#     inherit (config.boot) kernelPackage;
#   };
#   ebpf.loader  # the loader binary
#   ebpf.bpfObjs # attribute set of compiled .bpf.o files

{
  pkgs ? import <nixpkgs> { },
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
