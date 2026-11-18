#!/usr/bin/env bash

exec "$(dirname -- "$0")/mount-expiry-locked-mount.sh" \
  --expected-fix-id io-cq-overflow-wait-progress \
  --expected-oracle-id io-cq-wait-operation-safety \
  --expected-operation-kind io-cq-wait \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/io-cq-overflow-wait-progress.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/io-cq-overflow-wait-progress.sh \
  "$@"
