args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "asymmetric-key-missing-id";
      oracleId = "asymmetric-key-operation-safety";
      operationKind = "asymmetric-key";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/asymmetric-key-missing-id.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/asymmetric-key-missing-id.sh";
    };
  }
)
