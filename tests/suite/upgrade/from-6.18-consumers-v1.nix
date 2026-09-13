# Repeat inherited consumer checks on the supported cgroup-v1 boot.
args: import ./from-6.18-consumers.nix (args // { cgroupVersion = 1; })
