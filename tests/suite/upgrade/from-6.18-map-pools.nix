# Keep two identically named guests, each from a different installed ZFS pool,
# distinct and live across activation of the selected 6.18 userspace.
args: import ./from-6.18.nix (args // { crossPoolActivation = true; })
