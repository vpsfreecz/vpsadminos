args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "recursive-bind-namespace-loop";
      oracleId = "recursive-bind-operation-safety";
      operationKind = "recursive-bind";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/recursive-bind-namespace-loop.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/recursive-bind-namespace-loop.sh";
    };
  }
)
