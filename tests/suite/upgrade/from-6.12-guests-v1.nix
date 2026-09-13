# Exercise the same inherited real guest policies with legacy host controllers.
args: import ./from-6.12-guests.nix (args // { cgroupVersion = 1; })
