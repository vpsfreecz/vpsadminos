# Exercise the predecessor's running CT through the actual top monitor and
# sysinfo syscall before and after target activation.
args: import ./from-6.18.nix (args // { inheritedConsumers = true; })
