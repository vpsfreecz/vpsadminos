#!/bin/sh
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/result"

if TEST_RUNNER_REPO_REV="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null)"; then
  export TEST_RUNNER_REPO_REV
else
  unset TEST_RUNNER_REPO_REV
fi

nix build \
  --out-link "$ROOT/result/test-runner" \
  "$ROOT#test-runner" \
  > /dev/null

export TEST_RUNNER_REPO_ROOT="$ROOT"
exec "$ROOT/result/test-runner/bin/test-runner" "$@"
