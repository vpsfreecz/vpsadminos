#!/usr/bin/env bash

exec "$(dirname -- "$0")/bpf-atomic-fetch-precision.sh" \
  --expected-fix-id bpf-null-call-argument-precision \
  --expected-oracle-id bpf-null-call-argument-precision-operation-safety \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/bpf-null-call-argument-precision.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/bpf-null-call-argument-precision.sh \
  "$@"
