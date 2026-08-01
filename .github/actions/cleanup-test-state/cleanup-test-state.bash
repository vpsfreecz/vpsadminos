#!/usr/bin/env bash
set -euo pipefail

if [[ "$TEST_STATE_PREPARE_OUTCOME" != success ]]; then
  echo "Test state was not prepared successfully; nothing to clean"
  exit 0
fi

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

expected_directory="${state_root%/}/os-test-runner-${TEST_STATE_REPOSITORY_ID}-${TEST_STATE_RUN_ID}-${TEST_STATE_RUN_ATTEMPT}"

if [[ "$TEST_STATE_DIRECTORY" != "$expected_directory" ]]; then
  echo "::error::Refusing to clean unexpected test state directory '$TEST_STATE_DIRECTORY'"
  exit 1
fi

cleanup=false

case "$TEST_STATE_TEST_OUTCOME" in
  success | skipped)
    cleanup=true
    ;;
esac

if [[ "$TEST_STATE_UPLOAD_OUTCOME" == success ]]; then
  cleanup=true
fi

if [[ "$cleanup" != true ]]; then
  echo "::notice::Preserving unpublished test state at $TEST_STATE_DIRECTORY"
  exit 0
fi

rm -rf -- "$TEST_STATE_DIRECTORY"
echo "Removed test-runner state directory: $TEST_STATE_DIRECTORY"
