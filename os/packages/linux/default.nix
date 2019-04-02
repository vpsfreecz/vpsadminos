{ pkgs }:
let
  kernelPatches = pkgs.kernelPatches;
in
  pkgs.callPackage <nixpkgs/pkgs/os-specific/linux/kernel/linux-5.0.nix> {
    kernelPatches =
      [ kernelPatches.bridge_stp_helper
        # See pkgs/os-specific/linux/kernel/cpu-cgroup-v2-patches/README.md
        # when adding a new linux version
        # kernelPatches.cpu-cgroup-v2."4.11"
        kernelPatches.modinst_arg_list_too_long

        # vpsAdminOS patches
        rec {
          name = "000-sched_getaffinity_cfs_quota";
          patch = ./patches + "/${name}.patch";
        }
        rec {
          name = "010-allow_mknod";
          patch = ./patches + "/${name}.patch";
        }
        rec {
          name = "020-cgroup_increase_max_css_id_to_32_bit_int";
          patch = ./patches + "/${name}.patch";
        }
        rec {
          name = "030-cglimit_controller_v1";
          patch = ./patches + "/${name}.patch";
        }
        rec {
          name = "040-nfs_userns_root";
          patch = ./patches + "/${name}.patch";
        }
        rec {
          name = "050-fpu_exports";
          patch = ./patches + "/${name}.patch";
        }

        # br_netfilter in non-initial network namespaces
        # See:
        #   https://lkml.org/lkml/2018/11/7/681
        #   https://lore.kernel.org/patchwork/patch/1007863/
        #   https://lore.kernel.org/patchwork/patch/1007864/
        #   https://github.com/lxc/lxd/issues/5193
        rec {
          name = "101-br_netfilter-add-struct-netns_brnf";
          patch = ./patches + "/${name}.patch";
        }
        rec {
          name = "102-br_netfilter-namespace-bridge-netfilter-sysctls";
          patch = ./patches + "/${name}.patch";
        }
      ];
  }
