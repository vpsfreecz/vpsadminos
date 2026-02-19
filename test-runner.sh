#!/bin/sh
set -e
mkdir -p result
NIXPKGS_PATH="${NIXPKGS_PATH:-$(nix-instantiate --find-file nixpkgs)}"
nix-build --out-link result/test-runner --arg nixpkgsPath "$NIXPKGS_PATH" os/packages/test-runner/entry.nix > /dev/null
exec ./result/test-runner/bin/test-runner "$@"
