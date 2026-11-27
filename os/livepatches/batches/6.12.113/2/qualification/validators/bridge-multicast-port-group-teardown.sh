#!/usr/bin/env bash

exec "$(dirname -- "$0")/network-backlog-unregister-serialization.sh" \
  --expected-fix-id bridge-multicast-port-group-teardown \
  --expected-oracle-id bridge-multicast-operation-safety \
  --expected-operation-label 'bridge multicast membership and port lifecycle' \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/bridge-multicast-port-group-teardown.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/bridge-multicast-port-group-teardown.sh \
  "$@"
