#!/usr/bin/env bash

exec "$(dirname -- "$0")/mount-expiry-locked-mount.sh" \
  --expected-fix-id pidns-freezable-reaper-wait \
  --expected-oracle-id pidns-freezable-reaper-operation-safety \
  --expected-operation-kind pidns-freezer \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/pidns-freezable-reaper-wait.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/pidns-freezable-reaper-wait.sh \
  "$@"
