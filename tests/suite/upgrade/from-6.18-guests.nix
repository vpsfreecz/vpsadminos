# Keep guest service/DNS coverage separate from the lightweight switch cases.
args:
import ./from-6.18.nix (
  args
  // {
    guestPolicies = true;
    # The pinned 6.18 predecessor records recovery taint separately. Exercise
    # inherited taint on v2; the v1 guest case keeps its focused migration probe.
    inheritedRecoveryTaint = (args.cgroupVersion or 2) == 2;
  }
)
