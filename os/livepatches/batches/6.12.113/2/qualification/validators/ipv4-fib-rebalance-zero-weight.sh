#!/usr/bin/env bash

exec "$(dirname -- "$0")/network-backlog-unregister-serialization.sh" \
  --expected-fix-id ipv4-fib-rebalance-zero-weight \
  --expected-oracle-id ipv4-fib-rebalance-operation-safety \
  --expected-operation-label 'IPv4 multipath route rebalance' \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/ipv4-fib-rebalance-zero-weight.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/ipv4-fib-rebalance-zero-weight.sh \
  "$@"
