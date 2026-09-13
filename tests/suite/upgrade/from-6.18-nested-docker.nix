# Exercise an inherited Docker daemon and running nested workload on the
# pinned 6.18 predecessor's actual kernel, across the target userspace switch.
args: import ./from-6.18.nix (args // { nestedDocker = true; })
