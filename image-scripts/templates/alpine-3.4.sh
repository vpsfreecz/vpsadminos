readonly DISTNAME='alpine'
readonly RELVER='3.4'
readonly ARCH='x86_64'
readonly BASEURL="http://repository.fit.cvut.cz/mirrors/alpine/v$RELVER"

readonly APK="$INSTALL/apk.static"
readonly APK_KEYS_DIR="$INSTALL/keys"
readonly APK_KEYS_URI='http://alpinelinux.org/keys'
readonly APK_KEYS_SHA256="\
	9c102bcc376af1498d549b77bdbfa815ae86faa1d2d82f040e616b18ef2df2d4  alpine-devel@lists.alpinelinux.org-4a6a0840.rsa.pub
	2adcf7ce224f476330b5360ca5edb92fd0bf91c92d83292ed028d7c4e26333ab  alpine-devel@lists.alpinelinux.org-4d07755e.rsa.pub
	ebf31683b56410ecc4c00acd9f6e2839e237a3b62b5ae7ef686705c7ba0396a9  alpine-devel@lists.alpinelinux.org-5243ef4b.rsa.pub
	1bb2a846c0ea4ca9d0e7862f970863857fc33c32f5506098c636a62a726a847b  alpine-devel@lists.alpinelinux.org-524d27bb.rsa.pub
	12f899e55a7691225603d6fb3324940fc51cd7f133e7ead788663c2b7eecb00c  alpine-devel@lists.alpinelinux.org-5261cecb.rsa.pub"

# <svcname> <runlevel>
readonly RC_SERVICES="\
	mdev sysinit
	cgroups-mount boot
	bootmisc boot
	syslog boot
	networking default
	sshd default"

readonly EXTRAPKGS='openssh'
readonly TIMEZONE='Europe/Prague'


die() {
	local retval=$1; shift
	printf 'ERROR: %s\n' "$@" 1>&2
	exit $retval
}

fetch() {
	if [ "${DEBUG:-}" = 'yes' ]; then
		wget -T 10 -O - $@
	else
		wget -T 10 -O - -q $@
	fi
}

fetch-apk-keys() {
	local line keyname

	mkdir -p "$APK_KEYS_DIR"
	cd "$APK_KEYS_DIR"

	echo "$APK_KEYS_SHA256" | while read -r line; do
		keyname="${line##* }"
		if [ ! -f "$keyname" ]; then
			fetch "$APK_KEYS_URI/$keyname" > "$keyname"
		fi
		echo "$line" | sha256sum -c -
	done || die 2 'Failed to fetch or verify APK keys'

	cd - >/dev/null
}

fetch-apk-static() {
	local pkg_name='apk-tools-static'

	local pkg_ver=$(fetch "$BASEURL/main/$ARCH/APKINDEX.tar.gz" \
		| tar -xzO APKINDEX \
		| sed -n "/P:${pkg_name}/,/^$/ s/V:\(.*\)$/\1/p")

	[ -n "$pkg_ver" ] || die 2 "Cannot find a version of $pkg_name in APKINDEX"

	fetch "$BASEURL/main/$ARCH/${pkg_name}-${pkg_ver}.apk" \
		| tar -xz -C "$(dirname "$APK")" --strip-components=1 sbin/

	[ -f "$APK" ] || die 2 "$APK not found"

	local keyname=$(echo "$APK".*.pub | sed 's/.*\.SIGN\.RSA\.//')
	openssl dgst -sha1 \
		-verify "$APK_KEYS_DIR/$keyname" \
		-signature "$APK.SIGN.RSA.$keyname" \
		"$APK" || die 2 "Signature verification for $(basename "$APK") failed"

	# Note: apk doesn't return 0 for --version (will be fixed in next release).
	local out="$("$APK" --version)"
	echo "$out"

	[ "${out%% *}" = 'apk-tools' ] || die 3 "$(basename "$APK") --version failed"
}

install-base() {
	cd "$INSTALL"

	mkdir -p etc/apk
	echo "$BASEURL/main" > etc/apk/repositories
	cp /etc/resolv.conf etc/

	$APK --arch="$ARCH" --root=. --keys-dir="$APK_KEYS_DIR" \
		--update-cache --initdb add alpine-base \
		|| die 3 'Failed to install APK packages'

	cp "$BASEDIR"/files/cgroups-mount.initd etc/init.d/cgroups-mount
	chmod +x etc/init.d/cgroups-mount

	cd - >/dev/null
}


#=============================  Main  ==============================#

echo '==> Fetching and verifying APK keys...'
fetch-apk-keys

echo '==> Fetching apk-tools static binary...'
fetch-apk-static

echo "==> Installing Alpine Linux in $INSTALL..."
install-base

echo '==> Configuring Alpine Linux...'
configure-append <<EOF
export PATH="/bin:/sbin:$PATH"
rm -f /etc/mtab
ln -s /proc/mounts /etc/mtab

apk update
apk add $EXTRAPKGS

setup-timezone -z "$TIMEZONE"

touch /etc/network/interfaces

sed -ri 's/^([^#].*getty.*)$/#\1/' /etc/inittab

cat >> /etc/inittab <<_EOF_
# Does not work on Alpine, but OVZ script set_console.sh insists on these two
# lines. Luckily it does not mind they are commented out.
#1:2345:respawn:/sbin/agetty console 38400
#2:2345:respawn:/sbin/agetty tty2 38400

# vpsAdmin console
::respawn:/sbin/getty 38400 tty0
_EOF_

echo tty0 >> /etc/securetty

sed -i \
	-e 's/^#*rc_logger=.*/rc_logger="YES"/' \
	-e 's/^#*rc_sys=.*/rc_sys="openvz"/' \
	-e 's/^#*rc_controller_cgroups=.*/rc_controller_cgroups="NO"/' \
	/etc/rc.conf

echo "$RC_SERVICES" | while read svcname runlevel; do
	rc-update add \$svcname \$runlevel
done

# vpsAdmin doesn't set SSH key in new containers, so we must permit root login
# using password...
sed -i \
	-e 's/^#*PasswordAuthentication .*/PasswordAuthentication yes/' \
	-e 's/^#*PermitRootLogin .*/PermitRootLogin yes/' \
	/etc/ssh/sshd_config
EOF

run-configure

echo '==> Cleaning up...'
rm "$APK"*
