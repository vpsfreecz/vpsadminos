# Retain a predecessor-created live Podman workload inside an inherited CT.
args: import ./from-6.18.nix (args // { nestedPodman = true; })
