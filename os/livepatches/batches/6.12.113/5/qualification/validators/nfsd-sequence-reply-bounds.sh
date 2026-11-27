#!/usr/bin/env bash

EXPECTED_FIX_ID=nfsd-sequence-reply-bounds
EXPECTED_ORACLE_ID=nfsd-sequence-operation-safety
EXPECTED_ADAPTER=os/livepatches/batches/6.12.113/5/qualification/helpers/nfsd-sequence-operation-safety.nix
EXPECTED_VALIDATOR=os/livepatches/batches/6.12.113/5/qualification/validators/nfsd-sequence-reply-bounds.sh
REQUIRE_NFSD_SEQUENCE=true
source "$(dirname -- "$0")/../../../2/qualification/validators/storage-operation-common.sh"
storage_operation_validate "$@"
