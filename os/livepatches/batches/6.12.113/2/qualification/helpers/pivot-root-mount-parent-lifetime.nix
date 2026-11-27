args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "pivot-root-mount-parent-lifetime";
      oracleId = "pivot-root-operation-safety";
      operationKind = "pivot-root";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/pivot-root-mount-parent-lifetime.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/pivot-root-mount-parent-lifetime.sh";
    };
  }
)
