# Row 27: predecessor-created networkd bridge guest retained during activation.
# Keep it separate from existing fresh networkd and inherited DNS cases.
args: import ./from-6.18.nix (args // { inheritedNetworkd = true; })
