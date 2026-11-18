args:

import ./mount-expiry-locked-mount.nix (
  args
  // {
    profile = {
      fixId = "pidns-livepatch-reaper-progress";
      oracleId = "pidns-livepatch-operation-safety";
      operationKind = "pidns-freezer";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/pidns-livepatch-reaper-progress.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/pidns-livepatch-reaper-progress.sh";
    };
  }
)
