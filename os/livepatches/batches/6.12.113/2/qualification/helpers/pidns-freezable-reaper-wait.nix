args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "pidns-freezable-reaper-wait";
      oracleId = "pidns-freezable-reaper-operation-safety";
      operationKind = "pidns-freezer";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/pidns-freezable-reaper-wait.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/pidns-freezable-reaper-wait.sh";
    };
  }
)
