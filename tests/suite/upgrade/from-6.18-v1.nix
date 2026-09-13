# Reuse the predecessor pin; select cgroup v1 for both system generations.
args: import ./from-6.18.nix (args // { cgroupVersion = 1; })
