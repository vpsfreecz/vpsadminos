# Preserve predecessor-owned multirange identity maps and shared-user guests
# across activation of the selected 6.18 userspace.
args: import ./from-6.18.nix (args // { mappedActivation = true; })
