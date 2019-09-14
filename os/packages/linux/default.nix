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
            AUFS_FS y
            AUFS_BRANCH_MAX_127 y
            AUFS_SBILIST y
            AUFS_HNOTIFY y
            AUFS_HFSNOTIFY y
            AUFS_EXPORT y
            AUFS_INO_T_64 y
            AUFS_XATTR y
            AUFS_FHSM y
            AUFS_RDU y
            AUFS_DIRREN y
            AUFS_SHWH y
            AUFS_BR_RAMFS y
            AUFS_BR_FUSE y
            AUFS_POLL y
            AUFS_BR_HFSPLUS y
            AUFS_BDEV_LOOP y
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
      ];
  }
