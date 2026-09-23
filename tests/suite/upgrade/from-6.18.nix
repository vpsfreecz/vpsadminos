# Published 6.18 userspace before the compatibility re-review corrections.
import ./common.nix {
  name = "from-6.18";
  revision = "3cb830e596a7fed900bec49f50c9b6cf51e76bb5";
  kernelPrefix = "6.18.49";
  configuration = "os/configs/unstable.nix";
  # This predecessor pins kernel revision
  # fbda79346b89b2d2486edd22e4bbbca0154d96b7, which predates the downstream
  # kernfs-filter preservation fix. The machine boots that kernel, so entering a
  # container mount namespace from a helper detaches inherited proc subdirectory
  # submounts there; see the assertion in common.nix.
  kernelPreservesInheritedProcMounts = false;
}
