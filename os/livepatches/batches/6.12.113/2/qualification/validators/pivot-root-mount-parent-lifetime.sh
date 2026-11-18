#!/usr/bin/env bash

exec "$(dirname -- "$0")/mount-expiry-locked-mount.sh" \
  --expected-fix-id pivot-root-mount-parent-lifetime \
  --expected-oracle-id pivot-root-operation-safety \
  --expected-operation-kind pivot-root \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/pivot-root-mount-parent-lifetime.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/pivot-root-mount-parent-lifetime.sh \
  "$@"
