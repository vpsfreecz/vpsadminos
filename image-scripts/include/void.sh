DISTNAME="void-$VARIANT"
RELVER=$(date +%Y%m%d)
BASEURL=https://repo.voidlinux.eu/live/current
ROOTFS=

fetch() {
	local name
	local rx

	if [ "$VARIANT" == "musl" ] ; then
		rx='void-x86_64-musl-rootfs-\d+.tar.xz'
	else
		rx='void-x86_64-rootfs-\d+.tar.xz'
	fi

	# Fetch checksums to find out latest release name
	wget -O - "$BASEURL/sha256sums.txt" | grep -P "$rx" > "$DOWNLOAD/sha256sums.txt"

	# Extract the name
	name=$(grep -o -P "$rx" "$DOWNLOAD/sha256sums.txt")

	# Download rootfs
	wget -P "$DOWNLOAD" "$BASEURL/$name"

	if ! (cd "$DOWNLOAD" ; sha256sum -c sha256sums.txt) ; then
		warn "Checksum does not match"
		exit 1
	fi

	ROOTFS="$DOWNLOAD/$name"
}

extract() {
	tar -xJf "$ROOTFS" -C "$INSTALL"
}

configure-void() {
	configure-append <<EOF
echo nameserver 8.8.8.8 > /etc/resolv.conf
xbps-install -Syu
xbps-install -Syu
sed -i '$ i devtmpfs        /dev    devtmpfs mode=0755,nosuid       0       0' /etc/fstab
cp /etc/skel/.[^.]* /root/
usermod -s /bin/bash root
usermod -L root
ln -s /etc/sv/sshd /etc/runit/runsvdir/default/sshd
rm -f /etc/runit/runsvdir/default/agetty-tty{3..6}
echo > /etc/resolv.conf
EOF
}

generate-void() {
	fetch
	extract
	echo "#!/bin/bash" | configure-append
	configure-common
	configure-void
	run-configure
}
