#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
STATE_DIR="${STATE_DIR:-${TMPDIR:-/tmp}/os-test-runner-zfs-full-${RUN_ID}}"
JOBS="${JOBS:-1}"
PROFILE="${PROFILE:-full}"

mkdir -p "${STATE_DIR}"

# test-runner.sh requires nix-command support.
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"
export VPSADMINOS_ZFS_FULL_PROFILE="${VPSADMINOS_ZFS_FULL_PROFILE:-${PROFILE}}"

echo "run-id:    ${RUN_ID}"
echo "state-dir: ${STATE_DIR}"
echo "jobs:      ${JOBS}"
echo "profile:   ${VPSADMINOS_ZFS_FULL_PROFILE}"

exec "${ROOT}/test-runner.sh" test \
  -f \
  -j "${JOBS}" \
  --state-dir "${STATE_DIR}" \
  -t zfs-full \
  "$@"
