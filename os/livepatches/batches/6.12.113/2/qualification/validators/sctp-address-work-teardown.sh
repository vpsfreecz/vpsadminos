#!/usr/bin/env bash

exec "$(dirname -- "$0")/network-backlog-unregister-serialization.sh" \
  --expected-fix-id sctp-address-work-teardown \
  --expected-oracle-id sctp-address-work-operation-safety \
  --expected-operation-label 'SCTP namespace and socket lifecycle' \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/sctp-address-work-teardown.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/sctp-address-work-teardown.sh \
  "$@"
