#!/usr/bin/env bash

exec "$(dirname -- "$0")/mount-expiry-locked-mount.sh" \
  --expected-fix-id recursive-bind-namespace-loop \
  --expected-oracle-id recursive-bind-operation-safety \
  --expected-operation-kind recursive-bind \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/recursive-bind-namespace-loop.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/recursive-bind-namespace-loop.sh \
  "$@"
