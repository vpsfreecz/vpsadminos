#!/usr/bin/env bash

exec "$(dirname -- "$0")/mount-expiry-locked-mount.sh" \
  --expected-fix-id io-waitid-request-ownership \
  --expected-oracle-id io-waitid-operation-safety \
  --expected-operation-kind io-waitid \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/io-waitid-request-ownership.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/io-waitid-request-ownership.sh \
  "$@"
