#!/bin/sh
# Used to update keys in $APK_KEYS_SHA256
git clone --depth 1 git://git.alpinelinux.org/aports
pushd aports/main/alpine-keys
for key in $(ls *.pub) ; do
	echo -e "\t$(sha256sum $key)"
done
popd
