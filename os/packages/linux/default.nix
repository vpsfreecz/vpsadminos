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

        # Patch syscall sched_getaffinity() to limit the number of returned CPUs
        # based on CPU quota. This approach is rather flawed as the calling
        # process can also run on CPUs not reported by sched_getaffinity().
        # It is however useful for applications (such as nproc) that use this
        # call to deduce the number of threads/workers to start.
        rec {
          name = "000-sched_getaffinity_cfs_quota";
          patch = ./patches + "/${name}.patch";
        }

        # Allow mknod() within user namespaces on any mounted filesystem.
        # The created devices are also fully usable. We rely on the devices
        # cgroup to control access to mknod() itself and the created devices.
        rec {
          name = "010-allow_mknod";
          patch = ./patches + "/${name}.patch";
        }

        # Increase the system-wide maximum number of memory cgroups to 2^32.
        # The default limit of 2^16 is insufficient when running many containers.
        rec {
          name = "020-cgroup_increase_max_css_id_to_32_bit_int";
          patch = ./patches + "/${name}.patch";
        }

        # The cglimit cgroup controller is used to limit the number of cgroups
        # in other subsystems that processes can create. It is essential to
        # ensure that no container can exhaust the finite amount of cgroups.
        rec {
          name = "030-cglimit_controller_v1";
          patch = ./patches + "/${name}.patch";
        }

        # Add option root_uid to NFS exports. This is useful for exports that
        # are mounted to user namespaced containers. The container roots aren't
        # considered as privileged by the server, option root_uid can be used
        # to specify which user other than the global root should be considered
        # as privileged.
        # This patch also requires a counterpart patch of nfs-utils in userspace.
        rec {
          name = "040-nfs_userns_root";
          patch = ./patches + "/${name}.patch";
        }

        # Since Linux 5.0, __kernel_fpu_begin() and __kernel_fpu_end() were
        # replaced by GPL-only exports, which makes them unavailable to ZFS.
        # This patch removes the GPL-only restriction until ZFS can find
        # another solution than just not using the FPU.
        rec {
          name = "050-fpu_exports";
          patch = ./patches + "/${name}.patch";
        }

        # br_netfilter in non-initial network namespaces. Known to be used by
        # docker deployments.
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
