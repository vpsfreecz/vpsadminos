#!/bin/sh -x
# Usage: $0 <nixpkgs | _nopkg> <osctl | osctld> <build id>

set -e

PKGS="$1"
GEMDIR="$2"
GEM="$(basename $2)"

export OS_BUILD_ID="$3"

pushd "$GEMDIR"
pkg=$(rake build | grep -oP "pkg/.+\.gem")
version=$(echo $pkg | grep -oP "\d+\.\d+\.\d+\.build\d+")

gem inabox "$pkg"

[ "$PKGS" == "_nopkg" ] && exit

popd
pushd "$PKGS/$GEM"
rm -f Gemfile.lock gemset.nix
sed -ri "s/gem '$GEM'[^$]*/gem '$GEM', '$version'/" Gemfile

bundix -l
