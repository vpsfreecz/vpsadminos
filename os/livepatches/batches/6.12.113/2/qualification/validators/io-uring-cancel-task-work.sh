#!/usr/bin/env bash

exec "$(dirname -- "$0")/mount-expiry-locked-mount.sh" \
  --expected-fix-id io-uring-cancel-task-work \
  --expected-oracle-id io-uring-cancel-task-work-operation-safety \
  --expected-operation-kind io-cancel-task-work \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/io-uring-cancel-task-work.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/io-uring-cancel-task-work.sh \
  "$@"
