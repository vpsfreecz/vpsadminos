#!/usr/bin/env bash

EXPECTED_FIX_ID=ceph-monitor-command-ack-bounds
EXPECTED_ORACLE_ID=ceph-monitor-command-operation-safety
EXPECTED_ADAPTER=os/livepatches/batches/6.12.113/2/qualification/helpers/ceph-operation-safety.nix
EXPECTED_VALIDATOR=os/livepatches/batches/6.12.113/2/qualification/validators/ceph-monitor-command-ack-bounds.sh
source "$(dirname -- "$0")/storage-operation-common.sh"
storage_operation_validate "$@"
