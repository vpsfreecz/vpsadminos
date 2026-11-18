#!/usr/bin/env bash

exec "$(dirname -- "$0")/mount-expiry-locked-mount.sh" \
  --expected-fix-id coredump-parked-task-lifetime \
  --expected-oracle-id coredump-operation-safety \
  --expected-operation-kind coredump \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/coredump-parked-task-lifetime.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/coredump-parked-task-lifetime.sh \
  "$@"
