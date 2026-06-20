args@{ testArgs ? { }, ... }:
import ./ebpf.nix (
  args
  // {
    testArgs = testArgs // {
      includeBtfSystemd = true;
    };
  }
)
