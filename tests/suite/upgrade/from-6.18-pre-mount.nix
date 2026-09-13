# Hold an actual LXC pre-mount hook over the predecessor-to-target switch.
args: import ./from-6.18.nix (args // { mountingActivation = true; })
