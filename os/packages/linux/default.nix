{ pkgs }:
let
  kernelPatches = pkgs.kernelPatches;
in
  pkgs.callPackage <nixpkgs/pkgs/os-specific/linux/kernel/linux-4.19.nix> {
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

        # AppArmor patches
        rec {
          name = "0001-apparmor-patch-to-provide-compatibility-with-v2.x-ne";
          patch = (pkgs.fetchpatch {
            name = "${name}.patch";
            url = "https://gitlab.com/apparmor/apparmor/raw/master/kernel-patches/v4.17/${name}.patch";
            sha256 = "02ivm4wsjn14gvbry99g2kaykvmx6yjwsz5dzlmql2ms00szw2z2";
          });
        }
        rec {
          name = "0002-apparmor-af_unix-mediation";
          patch = (pkgs.fetchpatch {
            name = "${name}.patch";
            url = "https://gitlab.com/apparmor/apparmor/raw/master/kernel-patches/v4.17/${name}.patch";
            sha256 = "0dala2kx2yp6k7fbw2ca5zby7mppmd1mb0bkadi2fhr4ingb61kg";
          });
        }
        rec {
          name = "0003-apparmor-fix-use-after-free-in-sk_peer_label";
          patch = (pkgs.fetchpatch {
            name = "${name}.patch";
            url = "https://gitlab.com/apparmor/apparmor/raw/master/kernel-patches/v4.17/${name}.patch";
            sha256 = "1hqyl7im4yidvpc25fy04vyijvs9p4my8ja230l8hh01vq44nl2j";
          });
        }
        rec {
          name = "0001-UBUNTU-SAUCE-apparmor-fix-apparmor-mediating-locking";
          patch = (pkgs.fetchpatch {
            name = "${name}.patch";
            url = "https://launchpadlibrarian.net/380390953/${name}.patch";
            sha256 = "1119q8akhxsqdp7yf18257kzp9nhz2cjm5ivsj8krrxg026q0nwb";
          });
        }
      ];
  }
