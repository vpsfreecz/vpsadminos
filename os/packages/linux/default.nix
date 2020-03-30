{ pkgs, lib, fetchpatch, ... }:
let
  kernelPatches = pkgs.kernelPatches;

  mkConfig = attrs: lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v:
    "${k} ${v}"
  ) attrs);
in
  pkgs.callPackage ./linux-5.4.nix {
    kernelPatches =
      [ kernelPatches.bridge_stp_helper
        # See pkgs/os-specific/linux/kernel/cpu-cgroup-v2-patches/README.md
        # when adding a new linux version
        # kernelPatches.cpu-cgroup-v2."4.11"

        {
          name = "vpsadminos-kernel-config";
          patch = null;
          extraConfig = mkConfig {
            EXPERT = "y";

            CHECKPOINT_RESTORE = "y";
            CFS_BANDWIDTH = "y";

            MEMCG_32BIT_IDS = "y";
            CGROUP_CGLIMIT = "y";
            SYSLOG_NS = "y";

            # NFSv4 causes problems to osctl-exportfs. Upon NFS container
            # descruction, there's an issue with dentries still in use. We only
            # support NFSv3, so v4 can be disabled.
            NFSD_V4 = "n";

            PSI_DEFAULT_DISABLED = "y";
          };
        }
      ];
  }
