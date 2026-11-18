#!/usr/bin/env bash

EXPECTED_FIX_ID=nfsd-openowner-list-locking
EXPECTED_ORACLE_ID=nfsd-openowner-operation-safety
EXPECTED_ADAPTER=os/livepatches/batches/6.12.113/2/qualification/helpers/nfsd-openowner-operation-safety.nix
EXPECTED_VALIDATOR=os/livepatches/batches/6.12.113/2/qualification/validators/nfsd-openowner-list-locking.sh
source "$(dirname -- "$0")/storage-operation-common.sh"
storage_operation_validate "$@"
