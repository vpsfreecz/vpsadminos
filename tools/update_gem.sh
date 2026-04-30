#!/usr/bin/env bash
# Usage: $0 <nixpkgs | _nopkg> <osctl | osctld> <build id>

set -euxo pipefail

PKGS="$1"
GEMDIR="$2"
GEM="$(basename "$2")"

export OS_BUILD_ID="$3"

pushd "$GEMDIR" >/dev/null
[ -f Gemfile.lock ] && rm -f Gemfile.lock
bundle install
pkg=$(bundle exec rake build | grep -oP "pkg/.+\.gem")
version=$(echo $pkg | grep -oP "\d+\.\d+\.\d+\.build\d+")

gem inabox "$pkg"

[ "$PKGS" == "_nopkg" ] && exit

popd >/dev/null
pushd "$PKGS/$GEM" >/dev/null
rm -f Gemfile.lock gemset.nix
sed -ri "s/gem '$GEM'[^$]*/gem '$GEM', '$version'/" Gemfile

bundix -l
