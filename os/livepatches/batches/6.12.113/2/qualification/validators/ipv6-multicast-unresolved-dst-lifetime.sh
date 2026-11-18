#!/usr/bin/env bash

exec "$(dirname -- "$0")/network-backlog-unregister-serialization.sh" \
  --expected-fix-id ipv6-multicast-unresolved-dst-lifetime \
  --expected-oracle-id ipv6-multicast-routing-operation-safety \
  --expected-operation-label 'IPv6 multicast-router control and traffic' \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/ipv6-multicast-unresolved-dst-lifetime.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/ipv6-multicast-unresolved-dst-lifetime.sh \
  "$@"
