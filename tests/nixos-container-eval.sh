#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

nix eval --impure --json --file tests/nixos-container-modules-eval.nix
nix eval --impure --json --file tests/nixos-container-templates-eval.nix
nix eval --impure --json --file tests/nixos-container-standalone-eval.nix

error_log=$(mktemp)
trap 'rm -f "$error_log"' EXIT
for release in 21.11 99.99 26_05 unstable ''; do
  if nix eval --impure --json --file tests/nixos-container-unsupported-eval.nix \
    --apply "select: select \"$release\"" 2>"$error_log"; then
    echo "Unsupported release $release unexpectedly succeeded" >&2
    exit 1
  fi
  error_text=$(cat "$error_log")
  for expected in \
    "unsupported stable NixOS release '$release'" \
    'Known stable releases: 22.11, 23.05, 23.11, 24.05, 24.11, 25.05, 25.11, 26.05' \
    'Update the vpsadminos input' \
    'nixosModules.containerUnstable'; do
    if [[ "$error_text" != *"$expected"* ]]; then
      cat "$error_log" >&2
      echo "Missing unsupported-release guidance: $expected" >&2
      exit 1
    fi
  done
done
