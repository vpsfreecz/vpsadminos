# Keep real guest policy and persistence assertions on the 6.18 v1 boundary.
args: import ./from-6.18-guests.nix (args // { cgroupVersion = 1; })
