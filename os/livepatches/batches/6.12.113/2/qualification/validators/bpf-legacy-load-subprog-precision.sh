#!/usr/bin/env bash

exec "$(dirname -- "$0")/bpf-atomic-fetch-precision.sh" \
  --expected-fix-id bpf-legacy-load-subprog-precision \
  --expected-oracle-id bpf-legacy-load-subprog-precision-operation-safety \
  --expected-adapter os/livepatches/batches/6.12.113/2/qualification/helpers/bpf-legacy-load-subprog-precision.nix \
  --expected-validator os/livepatches/batches/6.12.113/2/qualification/validators/bpf-legacy-load-subprog-precision.sh \
  "$@"
