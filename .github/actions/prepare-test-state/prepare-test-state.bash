#!/usr/bin/env bash
set -euo pipefail

state_root=${TEST_STATE_ROOT:-/tmp}

for value_name in \
  TEST_STATE_REPOSITORY_ID \
  TEST_STATE_RUN_ID \
  TEST_STATE_RUN_ATTEMPT; do
  value=${!value_name:-}

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "::error::${value_name} must be a numeric GitHub identifier"
    exit 1
  fi
done

if [[ "$state_root" != /* || "$state_root" == / ]]; then
  echo "::error::TEST_STATE_ROOT must be an absolute directory below /"
  exit 1
fi

state_directory="${state_root%/}/os-test-runner-${TEST_STATE_REPOSITORY_ID}-${TEST_STATE_RUN_ID}-${TEST_STATE_RUN_ATTEMPT}"

rm -rf -- "$state_directory"
umask 077
mkdir -p -- "$state_directory"

echo "Prepared test-runner state directory: $state_directory"
printf 'TEST_RUNNER_STATE_DIR=%s\n' "$state_directory" >>"$GITHUB_ENV"
printf 'state-directory=%s\n' "$state_directory" >>"$GITHUB_OUTPUT"
