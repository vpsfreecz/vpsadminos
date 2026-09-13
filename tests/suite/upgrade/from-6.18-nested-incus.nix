# Retain a predecessor-created live Incus workload inside an inherited CT.
args: import ./from-6.18.nix (args // { nestedIncus = true; })
