args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "io-waitid-request-ownership";
      oracleId = "io-waitid-operation-safety";
      operationKind = "io-waitid";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/io-waitid-request-ownership.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/io-waitid-request-ownership.sh";
    };
  }
)
