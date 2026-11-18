args@{ ... }:

import ./tcp-reqsk-migration-timer-lifetime.nix (
  args
  // {
    profile = {
      fixId = "tcp-reqsk-refcount-cleanup-preparation";
      oracleId = "tcp-reqsk-refcount-cleanup-operation-safety";
      toolName = "tcp-reqsk-refcount-cleanup-operation";
      operationLabel = "TCP request refcount cleanup lifecycle";
    };
  }
)
