#!/bin/sh
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/result"

NIXPKGS_PATH="$(nix eval --raw "$ROOT#nixpkgsPath")"
export NIX_PATH="nixpkgs=$NIXPKGS_PATH${NIX_PATH:+:${NIX_PATH}}"

nix build \
  --out-link "$ROOT/result/test-runner" \
  "$ROOT#test-runner" \
  > /dev/null

exec "$ROOT/result/test-runner/bin/test-runner" "$@"
