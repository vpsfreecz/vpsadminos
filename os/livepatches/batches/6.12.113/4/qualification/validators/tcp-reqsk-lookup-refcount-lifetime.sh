#!/usr/bin/env bash

set -euo pipefail

exec "$(dirname -- "$0")/../../../3/qualification/validators/tcp-reqsk-migration-timer-lifetime.sh" \
  "$@" \
  --profile lookup
