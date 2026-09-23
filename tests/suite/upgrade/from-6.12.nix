# Frozen default-branch baseline before the 6.18 integration series.
import ./common.nix {
  name = "from-6.12";
  revision = "3cc31e39ba2880a311a1a5889521d2bc0d7e3e0f";
  kernelPrefix = "6.12.95";
}
