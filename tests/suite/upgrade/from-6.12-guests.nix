# Reuse the exact predecessor pin and the native switch scenario.
args: import ./from-6.12.nix (args // { guestPolicies = true; })
