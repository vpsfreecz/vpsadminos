# Exercise the existing installer against a real persistent ZFS root.
args: import ./install.nix (args // { rootFs = "zfs"; })
