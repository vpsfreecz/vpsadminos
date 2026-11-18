#!/usr/bin/env bash

exec "$(dirname -- "$0")/mount-expiry-locked-mount.sh" \
  --expected-fix-id asymmetric-key-missing-id \
  --expected-oracle-id asymmetric-key-operation-safety \
  --expected-operation-kind asymmetric-key \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/asymmetric-key-missing-id.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/asymmetric-key-missing-id.sh \
  "$@"
