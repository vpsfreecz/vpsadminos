BASEURL=https://mirror.vpsfree.cz/gentoo

require_cmd curl

STAGE3_BASE_URL="${BASEURL}/releases/amd64/autobuilds"
STAGE3_TARBALL_URL=
STAGE3_TARBALL=

fetch() {
	STAGE3_TARBALL_URL="${STAGE3_BASE_URL}/$(curl "${STAGE3_BASE_URL}/latest-stage3-amd64-${VARIANT}.txt" | grep -o -m 1 -P "^[\dTZ]+/stage3-amd64-${VARIANT}-[\dTZ]+.tar.xz")"
	STAGE3_TARBALL="$(basename $STAGE3_TARBALL_URL)"

	wget -P "$DOWNLOAD" ${STAGE3_TARBALL_URL}{.CONTENTS.gz,.DIGESTS,}

	if ! (cd "$DOWNLOAD"; sed -rn '/# SHA512/ {N;p}' "${STAGE3_TARBALL}".DIGESTS | sha512sum -c);
	then
		echo "Stage 3 checksum wrong! Quitting."
		exit 1
	fi
}

extract() {
	echo "Unpacking Stage3..."
	tar xJpf "${DOWNLOAD}/${STAGE3_TARBALL}" -C "$INSTALL"
}

configure-gentoo-begin() {
	cp /etc/resolv.conf "$INSTALL"/etc/

	configure-append <<EOF
export PATH="/bin:/sbin:/usr/bin:$PATH"
EOF

	configure-common

	configure-append <<EOF
echo 'LANG="en_US.UTF-8"' >/etc/env.d/02locale
echo 'GENTOO_MIRRORS="$BASEURL/ http://ftp.fi.muni.cz/pub/linux/gentoo/"' >> /etc/portage/make.conf
echo "Europe/Prague" > /etc/timezone

emerge-webrsync -v

# Create a temporary make.conf
cp -p /etc/portage/make.conf /etc/portage/make.conf.orig
echo 'MAKEOPTS="-j$(nproc)"' >> /etc/portage/make.conf

emerge --update --deep --newuse --with-bdeps=y --backtrack=120 @system @world
emerge net-misc/dhcpcd sys-apps/iproute2 app-editors/vim
EOF
}

configure-gentoo-end() {
	configure-append <<EOF
# Restore original make.conf
mv /etc/portage/make.conf.orig /etc/portage/make.conf

eselect news read

sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

> /etc/resolv.conf

rm -f /usr/portage/distfiles/*
EOF
}
