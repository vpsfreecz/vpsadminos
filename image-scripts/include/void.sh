require_cmd wget

BASEURL=http://alpha.de.repo.voidlinux.org/live/current
ROOTFS=

fetch() {
	local name
	local rx

	if [ "$VARIANT" == "musl" ] ; then
		rx='void-x86_64-musl-ROOTFS-\d+.tar.xz'
	else
		rx='void-x86_64-ROOTFS-\d+.tar.xz'
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
xbps-install -Syu vim
cp /etc/skel/.[^.]* /root/
usermod -s /bin/bash root
usermod -L root
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
ln -s /etc/sv/sshd /etc/runit/runsvdir/default/sshd
rm -f /etc/runit/runsvdir/default/agetty-tty{1..6}
rm -f /etc/runit/runsvdir/default/udevd
ln -s /etc/sv/agetty-console /etc/runit/runsvdir/default/agetty-console
echo > /etc/resolv.conf
EOF
}

generate-void() {
	fetch
	extract
	configure-shebang "#!/bin/bash"
	configure-common
	configure-void
	run-configure
}
