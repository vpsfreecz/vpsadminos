#!/usr/bin/env bash

exec "$(dirname -- "$0")/mount-expiry-locked-mount.sh" \
  --expected-fix-id request-key-auth-payload-lifetime \
  --expected-oracle-id request-key-operation-safety \
  --expected-operation-kind request-key \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/request-key-auth-payload-lifetime.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/request-key-auth-payload-lifetime.sh \
  "$@"
