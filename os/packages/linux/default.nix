{ pkgs }:
let
  kernelPatches = pkgs.kernelPatches;
in
  pkgs.callPackage <nixpkgs/pkgs/os-specific/linux/kernel/linux-4.17.nix> {
    kernelPatches =
      [ kernelPatches.bridge_stp_helper
        # See pkgs/os-specific/linux/kernel/cpu-cgroup-v2-patches/README.md
        # when adding a new linux version
        # kernelPatches.cpu-cgroup-v2."4.11"
        kernelPatches.modinst_arg_list_too_long
        kernelPatches.bcm2835_mmal_v4l2_camera_driver # Only needed for 4.16!
        { name = "sched_getaffinity_cfs_quota";
          patch = ./sched_getaffinity_cfs_quota.patch; }
      ];    
  }
