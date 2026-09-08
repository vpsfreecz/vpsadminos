# Published 6.18 userspace before the compatibility re-review corrections.
import ./common.nix {
  name = "from-6.18";
  revision = "3cb830e596a7fed900bec49f50c9b6cf51e76bb5";
  kernelPrefix = "6.18.49";
  configuration = "os/configs/unstable.nix";
}
