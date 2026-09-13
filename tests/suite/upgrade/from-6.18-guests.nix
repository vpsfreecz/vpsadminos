# Keep guest service/DNS coverage separate from the lightweight switch cases.
args: import ./from-6.18.nix (args // { guestPolicies = true; })
