# Rows 9, 30 and 31: rollback→forward, management operations in flight, and a
# predecessor-created stream imported after userspace activation, on the same predecessor
# pin and guest policies as from-6.12-guests. Isolated in its own case so the
# ten existing upgrade cases stay untouched.
args:
import ./common.nix
  {
    name = "from-6.12-inherited";
    revision = "3cc31e39ba2880a311a1a5889521d2bc0d7e3e0f";
    kernelPrefix = "6.12.95";
  }
  (
    args
    // {
      guestPolicies = true;
      reverseActivation = true;
      overlapActivation = true;
      transferAcrossActivation = true;
    }
  )
