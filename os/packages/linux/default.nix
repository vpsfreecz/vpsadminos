{ pkgs, fetchpatch, ... }:
let
  kernelPatches = pkgs.kernelPatches;
in
  pkgs.callPackage ./linux-5.2.nix {
    kernelPatches =
      [ kernelPatches.bridge_stp_helper
        # See pkgs/os-specific/linux/kernel/cpu-cgroup-v2-patches/README.md
        # when adding a new linux version
        # kernelPatches.cpu-cgroup-v2."4.11"
        kernelPatches.modinst_arg_list_too_long

        {
          name = "vpsadminos-kernel-config";
          patch = null;
          extraConfig = ''
            EXPERT y
            CHECKPOINT_RESTORE y
            CFS_BANDWIDTH y
            MEMCG_32BIT_IDS y
            CGROUP_CGLIMIT y
            SYSLOG_NS y
          '';
        }

        # br_netfilter in non-initial network namespaces. Known to be used by
        # docker deployments.
        # See:
        #   https://lkml.org/lkml/2018/11/7/681
        #   https://lore.kernel.org/patchwork/patch/1007863/
        #   https://lore.kernel.org/patchwork/patch/1007864/
        #   https://github.com/lxc/lxd/issues/5193
        rec {
          name = "br_netfilter_namespace";
          patch = fetchpatch {
            name = name + ".patch";
            url = https://github.com/vpsfreecz/linux/compare/e93c9c99a629c61837d5a7fc2120cd2b6c70dbdd...b78bce45f60a80c3eacfe4b10aeab48e11d29eeb.patch;
            sha256 = "1dvlhqbj3c7ml5gqgnpy0xmcbc9k0plnh7v23kjijjz9zpadw1hz";
          };
        }

        # Let first-level user namespaces (osctl containers) to manipulate
        # oom_score_adj and oom_score_adj_min with CAP_SYS_RESOURCE.
        rec {
          name = "oom_score_adj_min";
          patch = fetchpatch {
            name = name + ".patch";
            url = https://github.com/vpsfreecz/linux/commit/455e1606a25463196f0788b5c46d6a5c0a359529.patch;
            sha256 = "15bzmww5qpc37daxk26w2xmzb53sfdfxk674vvv9jlcxg9k0ds4v";
          };
        }
      ];
  }
