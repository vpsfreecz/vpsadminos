#!/usr/bin/env bash

exec "$(dirname -- "$0")/bpf-atomic-fetch-precision.sh" \
  --expected-fix-id bpf-callback-frame-precision \
  --expected-oracle-id bpf-callback-frame-precision-operation-safety \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/bpf-callback-frame-precision.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/bpf-callback-frame-precision.sh \
  "$@"
