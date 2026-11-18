#!/usr/bin/env bash

exec "$(dirname -- "$0")/mount-expiry-locked-mount.sh" \
  --expected-fix-id io-wq-exit-signal \
  --expected-oracle-id io-wq-operation-safety \
  --expected-operation-kind io-wq \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/io-wq-exit-signal.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/io-wq-exit-signal.sh \
  "$@"
