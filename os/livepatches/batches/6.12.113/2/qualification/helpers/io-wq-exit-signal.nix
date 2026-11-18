args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "io-wq-exit-signal";
      oracleId = "io-wq-operation-safety";
      operationKind = "io-wq";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/io-wq-exit-signal.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/io-wq-exit-signal.sh";
    };
  }
)
