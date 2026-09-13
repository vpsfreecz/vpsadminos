# Retain a genuinely frozen predecessor-created guest through activation and
# both kinds of real daemon restart, then thaw it under the target userspace.
args: import ./from-6.18.nix (args // { frozenActivation = true; })
