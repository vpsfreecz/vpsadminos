args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "io-cq-overflow-wait-progress";
      oracleId = "io-cq-wait-operation-safety";
      operationKind = "io-cq-wait";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/io-cq-overflow-wait-progress.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/io-cq-overflow-wait-progress.sh";
    };
  }
)
