#!/usr/bin/env bash

exec "$(dirname -- "$0")/mount-expiry-locked-mount.sh" \
  --expected-fix-id pidns-livepatch-reaper-progress \
  --expected-oracle-id pidns-livepatch-operation-safety \
  --expected-operation-kind pidns-freezer \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/pidns-livepatch-reaper-progress.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/pidns-livepatch-reaper-progress.sh \
  "$@"
