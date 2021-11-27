#!/bin/sh
# Used to update keys in $APK_KEYS_SHA256
wget -r -l 1 https://alpinelinux.org/keys/
pushd alpinelinux.org/keys
for key in $(ls *.pub) ; do
	echo -e "\t$(sha256sum $key)"
done
popd
