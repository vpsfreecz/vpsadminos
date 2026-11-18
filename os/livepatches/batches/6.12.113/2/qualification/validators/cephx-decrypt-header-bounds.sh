#!/usr/bin/env bash

EXPECTED_FIX_ID=cephx-decrypt-header-bounds
EXPECTED_ORACLE_ID=cephx-auth-operation-safety
EXPECTED_ADAPTER=os/livepatches/batches/6.12.113/2/qualification/helpers/ceph-operation-safety.nix
EXPECTED_VALIDATOR=os/livepatches/batches/6.12.113/2/qualification/validators/cephx-decrypt-header-bounds.sh
source "$(dirname -- "$0")/storage-operation-common.sh"
storage_operation_validate "$@"
