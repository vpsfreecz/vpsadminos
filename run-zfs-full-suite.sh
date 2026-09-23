#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
STATE_DIR="${STATE_DIR:-${TMPDIR:-/tmp}/os-test-runner-zfs-full-${RUN_ID}}"
JOBS="${JOBS:-1}"
PROFILE="${VPSADMINOS_ZFS_FULL_PROFILE:-${PROFILE:-full}}"

if [[ -z "${TIMEOUT:-}" ]]; then
  if [[ -n "${VPSADMINOS_ZFS_FULL_TEST:-}" ]]; then
    # The in-VM single-test bound is two hours. Leave an hour for startup,
    # result capture, and orderly shutdown.
    TIMEOUT=$((3 * 60 * 60))
  else
    case "${PROFILE}" in
      full)
        # The in-VM full-suite bound is twelve hours.
        TIMEOUT=$((13 * 60 * 60))
        ;;
      sanity)
        # The in-VM sanity bound is three hours.
        TIMEOUT=$((4 * 60 * 60))
        ;;
      smoke)
        # The in-VM smoke bound is one hour.
        TIMEOUT=$((2 * 60 * 60))
        ;;
      *)
        echo "Unsupported ZFS full-suite profile: ${PROFILE}" >&2
        exit 2
        ;;
    esac
  fi
fi

mkdir -p "${STATE_DIR}"

# test-runner.sh requires nix-command support.
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"
export VPSADMINOS_ZFS_FULL_PROFILE="${PROFILE}"

echo "run-id:    ${RUN_ID}"
echo "state-dir: ${STATE_DIR}"
echo "jobs:      ${JOBS}"
echo "profile:   ${VPSADMINOS_ZFS_FULL_PROFILE}"
echo "timeout:   ${TIMEOUT}"
echo "runfiles:  ${VPSADMINOS_ZFS_FULL_RUNFILES:-<profile default>}"
echo "tags:      ${VPSADMINOS_ZFS_FULL_TAGS:-<profile default>}"
echo "builtin:   ${VPSADMINOS_ZFS_FULL_USE_BUILTIN:-0}"

exec "${ROOT}/test-runner.sh" test \
  -f \
  -j "${JOBS}" \
  --timeout "${TIMEOUT}" \
  --state-dir "${STATE_DIR}" \
  -t zfs-full \
  "$@"
