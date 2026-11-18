#!/usr/bin/env bash

exec "$(dirname -- "$0")/network-backlog-unregister-serialization.sh" \
  --expected-fix-id conntrack-nonclosing-rst-timeout \
  --expected-oracle-id conntrack-tcp-operation-safety \
  --expected-operation-label 'ordinary tracked TCP connection lifecycle' \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/conntrack-nonclosing-rst-timeout.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/conntrack-nonclosing-rst-timeout.sh \
  "$@"
