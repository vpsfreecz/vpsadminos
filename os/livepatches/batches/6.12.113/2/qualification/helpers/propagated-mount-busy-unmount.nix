args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "propagated-mount-busy-unmount";
      oracleId = "mount-propagation-operation-safety";
      operationKind = "mount-propagation";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/propagated-mount-busy-unmount.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/propagated-mount-busy-unmount.sh";
    };
  }
)
