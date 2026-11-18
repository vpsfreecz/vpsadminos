#!/usr/bin/env bash

EXPECTED_FIX_ID=ceph-mdsmap-rank-bounds
EXPECTED_ORACLE_ID=ceph-mdsmap-operation-safety
EXPECTED_ADAPTER=os/livepatches/batches/6.12.113/2/qualification/helpers/ceph-operation-safety.nix
EXPECTED_VALIDATOR=os/livepatches/batches/6.12.113/2/qualification/validators/ceph-mdsmap-rank-bounds.sh
source "$(dirname -- "$0")/storage-operation-common.sh"
storage_operation_validate "$@"
