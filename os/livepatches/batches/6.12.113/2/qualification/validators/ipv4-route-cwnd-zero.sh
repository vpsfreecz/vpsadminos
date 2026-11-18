#!/usr/bin/env bash

exec "$(dirname -- "$0")/network-backlog-unregister-serialization.sh" \
  --expected-fix-id ipv4-route-cwnd-zero \
  --expected-oracle-id ipv4-route-metrics-operation-safety \
  --expected-operation-label 'valid locked nonzero route cwnd traffic' \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/ipv4-route-cwnd-zero.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/ipv4-route-cwnd-zero.sh \
  "$@"
