{
  # Native 6.12.110 continuity instance (A19 / A11 case 13 "F"): the booted
  # kernel is the reviewed .110 candidate itself; no livepatch is present or
  # loadable, and the terminal NFS cancellation ABI must be native. The full
  # NFS sysfs-ABI and behavioral continuity rows run on the .110 image with the
  # NFS harness at Step 17/22; this instance carries the boot/identity subset.
  native = true;
  bootModule = ../../../configs/vpsadminos/livepatch-6.12.110-native.nix;
}
