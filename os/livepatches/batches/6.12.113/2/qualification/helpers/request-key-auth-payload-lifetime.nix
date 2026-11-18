args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "request-key-auth-payload-lifetime";
      oracleId = "request-key-operation-safety";
      operationKind = "request-key";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/request-key-auth-payload-lifetime.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/request-key-auth-payload-lifetime.sh";
    };
  }
)
