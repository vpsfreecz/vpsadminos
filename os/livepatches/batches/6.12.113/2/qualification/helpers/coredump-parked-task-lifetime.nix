args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "coredump-parked-task-lifetime";
      oracleId = "coredump-operation-safety";
      operationKind = "coredump";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/coredump-parked-task-lifetime.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/coredump-parked-task-lifetime.sh";
    };
  }
)
