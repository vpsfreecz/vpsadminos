#!/usr/bin/env bash

set -euo pipefail

exec "$(dirname -- "$0")/tcp-reqsk-migration-timer-lifetime.sh" \
  "$@" \
  --profile cleanup
