args@{ ... }:

import ../../../3/qualification/helpers/tcp-reqsk-migration-timer-lifetime.nix (
  args
  // {
    profile = {
      fixId = "tcp-reqsk-lookup-refcount-lifetime";
      oracleId = "tcp-reqsk-lookup-lifetime-operation-safety";
      toolName = "tcp-reqsk-lookup-lifetime-operation";
      operationLabel = "IPv4 and IPv6 request lookup refcount lifecycle";
    };
  }
)
