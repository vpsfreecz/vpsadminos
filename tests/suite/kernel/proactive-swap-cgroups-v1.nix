import ../../make-test.nix (
  { pkgs }:
  import ./proactive-swap-common.nix {
    inherit pkgs;
    cgroupsVersion = 1;
  }
)
