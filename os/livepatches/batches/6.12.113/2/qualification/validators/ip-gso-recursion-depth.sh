#!/usr/bin/env bash

exec "$(dirname -- "$0")/network-backlog-unregister-serialization.sh" \
  --expected-fix-id ip-gso-recursion-depth \
  --expected-oracle-id ip-gso-tunnel-operation-safety \
  --expected-operation-label 'shallow IP tunnel TCP GSO traffic' \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/ip-gso-recursion-depth.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/ip-gso-recursion-depth.sh \
  "$@"
