#!/usr/bin/env bash

exec "$(dirname -- "$0")/network-backlog-unregister-serialization.sh" \
  --expected-fix-id skb-zerocopy-shared-frag \
  --expected-oracle-id nfqueue-xfrm-operation-safety \
  --expected-operation-label 'NFQUEUE acceptance of ordinary XFRM traffic' \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/skb-zerocopy-shared-frag.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/skb-zerocopy-shared-frag.sh \
  "$@"
