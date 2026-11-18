args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "io-uring-cancel-task-work";
      oracleId = "io-uring-cancel-task-work-operation-safety";
      operationKind = "io-cancel-task-work";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/io-uring-cancel-task-work.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/io-uring-cancel-task-work.sh";
    };
  }
)
