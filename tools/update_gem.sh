#!/bin/sh -x
# Usage: $0 <nixpkgs> osctl | osctld

set -e

PKGS="$1"
GEM="$2"

pushd "$GEM"
pkg=$(VPSADMIN_ENV=dev rake build | grep -oP "pkg/.+\.gem")
version=$(echo $pkg | grep -oP "\d+\.\d+\.\d+\.build\d+")

gem inabox "$pkg"

popd
pushd "$PKGS/$GEM"
rm -f Gemfile.lock gemset.nix
sed -ri "s/gem '$GEM'[^$]*/gem '$GEM', '$version'/" Gemfile

bundix -l
