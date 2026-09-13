# A supported compatibility boundary, not a claim about live fleet inventory.
# Boot 6.12, activate the published 6.18 userspace, then activate the candidate.
import ./common.nix {
  name = "from-6.12-via-6.18";
  revision = "3cc31e39ba2880a311a1a5889521d2bc0d7e3e0f";
  kernelPrefix = "6.12.95";
  activated = {
    revision = "3cb830e596a7fed900bec49f50c9b6cf51e76bb5";
    configuration = "os/configs/unstable.nix";
  };
}
