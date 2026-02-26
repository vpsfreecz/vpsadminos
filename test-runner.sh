#!/bin/sh
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/result"

nix build \
  --out-link "$ROOT/result/test-runner" \
  "$ROOT#test-runner" \
  > /dev/null

exec "$ROOT/result/test-runner/bin/test-runner" "$@"
