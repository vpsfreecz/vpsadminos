require_cmd wget

BASEURL=https://repo.chimera-linux.org/live/latest
ROOTFS=

fetch() {
	local name
	local rx

	rx='chimera-linux-x86_64-ROOTFS-\d+-bootstrap.tar.gz'

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
	tar -xzf "$ROOTFS" -C "$INSTALL"
}

configure-chimera() {
	configure-append <<EOF
echo nameserver 8.8.8.8 > /etc/resolv.conf
apk update
apk upgrade --available
apk add chimera-repo-contrib
apk update
apk add base-full base-vpsfree
apk del chimerautils
usermod -L root
sed -i '' 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i '' 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
echo > /etc/resolv.conf
EOF
}

generate-chimera() {
	fetch
	extract
	configure-shebang "#!/bin/sh"
	configure-common
	configure-chimera
	run-configure
}
