# Keep all three generations on the booted host's cgroup-v1 hierarchy.
args: import ./from-6.12-via-6.18.nix (args // { cgroupVersion = 1; })
