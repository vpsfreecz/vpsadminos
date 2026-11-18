#!/usr/bin/env bash

EXPECTED_FIX_ID=ceph-snap-trace-count-bounds
EXPECTED_ORACLE_ID=ceph-snapshot-operation-safety
EXPECTED_ADAPTER=os/livepatches/batches/6.12.113/2/qualification/helpers/ceph-operation-safety.nix
EXPECTED_VALIDATOR=os/livepatches/batches/6.12.113/2/qualification/validators/ceph-snap-trace-count-bounds.sh
source "$(dirname -- "$0")/storage-operation-common.sh"
storage_operation_validate "$@"
