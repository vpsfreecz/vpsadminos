args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "io-uring-cancel-local-work";
      oracleId = "io-uring-cancel-operation-safety";
      operationKind = "io-cancel";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/io-uring-cancel-local-work.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/io-uring-cancel-local-work.sh";
    };
  }
)
