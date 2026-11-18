#!/usr/bin/env bash

exec "$(dirname -- "$0")/network-backlog-unregister-serialization.sh" \
  --expected-fix-id tc-action-release-ordering \
  --expected-oracle-id tc-action-lifecycle-operation-safety \
  --expected-operation-label 'traffic-control action create use and delete' \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/tc-action-release-ordering.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/tc-action-release-ordering.sh \
  "$@"
