#!/usr/bin/env bash

exec "$(dirname -- "$0")/mount-expiry-locked-mount.sh" \
  --expected-fix-id propagated-mount-busy-unmount \
  --expected-oracle-id mount-propagation-operation-safety \
  --expected-operation-kind mount-propagation \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/propagated-mount-busy-unmount.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/propagated-mount-busy-unmount.sh \
  "$@"
