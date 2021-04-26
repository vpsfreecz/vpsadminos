#!/bin/sh
set -e
mkdir -p result
nix-build --out-link result/test-runner os/packages/test-runner/entry.nix > /dev/null
exec ./result/test-runner/bin/test-runner "$@"
