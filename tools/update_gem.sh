#!/usr/bin/env bash
# Usage: $0 <nixpkgs | _nopkg> <osctl | osctld> <build id>

set -euxo pipefail

PKGS="$1"
GEMDIR="$2"
GEM="$(basename "$2")"

export OS_BUILD_ID="$3"

REMOTE_GEM_SOURCE="${VPSADMINOS_GEM_SOURCE_URL:-https://rubygems.vpsfree.cz}"
LOCAL_GEMINABOX_URL="${VPSADMINOS_GEMINABOX_URL:-}"
TMP_BUNDLE_APP_CONFIG=""
PACKAGE_SOURCE_REWRITE_ACTIVE=0

setup_bundle_source_mirror() {
	if [ -z "$LOCAL_GEMINABOX_URL" ]; then
		return
	fi

	if [ -z "$TMP_BUNDLE_APP_CONFIG" ]; then
		TMP_BUNDLE_APP_CONFIG="$(mktemp -d)"
		export BUNDLE_APP_CONFIG="$TMP_BUNDLE_APP_CONFIG"
	fi

	bundle config set --local "mirror.$REMOTE_GEM_SOURCE" "$LOCAL_GEMINABOX_URL"
	bundle config set --local "mirror.$REMOTE_GEM_SOURCE.fallback_timeout" 0
}

replace_source_url() {
	local from="$1"
	local to="$2"
	shift 2

	for file in "$@"; do
		[ -f "$file" ] || continue
		sed -i "s|$from|$to|g" "$file"
	done
}

use_local_package_source() {
	if [ -z "$LOCAL_GEMINABOX_URL" ]; then
		return
	fi

	PACKAGE_SOURCE_REWRITE_ACTIVE=1
	replace_source_url "$REMOTE_GEM_SOURCE" "$LOCAL_GEMINABOX_URL" Gemfile
}

restore_canonical_package_source() {
	if [ "$PACKAGE_SOURCE_REWRITE_ACTIVE" != 1 ]; then
		return
	fi

	replace_source_url "$LOCAL_GEMINABOX_URL" "$REMOTE_GEM_SOURCE" Gemfile Gemfile.lock gemset.nix
	PACKAGE_SOURCE_REWRITE_ACTIVE=0
}

cleanup() {
	restore_canonical_package_source || true

	if [ -n "$TMP_BUNDLE_APP_CONFIG" ]; then
		rm -rf "$TMP_BUNDLE_APP_CONFIG"
	fi
}
trap cleanup EXIT

pushd "$GEMDIR" >/dev/null
[ -f Gemfile.lock ] && rm -f Gemfile.lock
setup_bundle_source_mirror
bundle install
pkg=$(bundle exec rake build | grep -oP "pkg/.+\.gem")
version=$(echo $pkg | grep -oP "\d+\.\d+\.\d+\.build\d+")

if [ -n "$LOCAL_GEMINABOX_URL" ]; then
	gem inabox --host "$LOCAL_GEMINABOX_URL" "$pkg"
else
	gem inabox "$pkg"
fi

[ "$PKGS" == "_nopkg" ] && exit

popd >/dev/null
pushd "$PKGS/$GEM" >/dev/null
rm -f Gemfile.lock gemset.nix
sed -ri "s/gem '$GEM'[^$]*/gem '$GEM', '$version'/" Gemfile

setup_bundle_source_mirror
use_local_package_source
bundix -l
restore_canonical_package_source
