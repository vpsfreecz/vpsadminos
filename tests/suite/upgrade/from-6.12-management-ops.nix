# Row 30: old-to-new userspace activation while start/copy commands remain
# blocked in their real predecessor hooks. Keep this independent of the
# already-passing inherited exec/runscript/client continuity fixture.
args:
import ./common.nix {
  name = "from-6.12-management-ops";
  revision = "3cc31e39ba2880a311a1a5889521d2bc0d7e3e0f";
  kernelPrefix = "6.12.95";
} (args // { managementActivation = true; })
