. "$TEMPLATEDIR/config.sh"
BASEURL=https://mirror.vpsfree.cz/gentoo

require_cmd curl

STAGE3BASEURL="${BASEURL}/releases/amd64/autobuilds"
STAGE3TARBALLURL="${STAGE3BASEURL}/$(curl "${STAGE3BASEURL}/latest-stage3-amd64.txt" | grep -o -m 1 -P '^[\dTZ]+/stage3-amd64-[\dTZ]+.tar.xz')"
STAGE3TARBALL="$(basename $STAGE3TARBALLURL)"


wget -P $DOWNLOAD ${STAGE3TARBALLURL}{.CONTENTS,.DIGESTS,}

if ! (cd $DOWNLOAD; sed -rn '/# SHA512/ {N;p}' ${STAGE3TARBALL}.DIGESTS | sha512sum -c);
then
	echo "Stage 3 checksum wrong! Quitting."
	exit 1
fi

echo "Unpacking Stage3..."
tar xJpf ${DOWNLOAD}/${STAGE3TARBALL} -C $INSTALL

cp /etc/resolv.conf $INSTALL/etc/

configure-append <<EOF
export PATH="/bin:/sbin:/usr/bin:$PATH"
EOF

configure-common

configure-append <<EOF
echo 'LANG="en_US.UTF-8"' >/etc/env.d/02locale
echo 'GENTOO_MIRRORS="$BASEURL/ http://ftp.fi.muni.cz/pub/linux/gentoo/"' >> /etc/portage/make.conf
echo "Europe/Prague" > /etc/timezone
emerge-webrsync -v
sed -i '/^USE=/d' /etc/portage/make.conf
echo 'USE="-udev"' >> /etc/portage/make.conf
echo "=sys-apps/openrc-0.35* ~amd64" > /etc/portage/package.keywords/template
echo "sys-apps/busybox mdev" > /etc/portage/package.use/template
emerge --unmerge udev
emerge --update --deep --newuse --with-bdeps=y --backtrack=120 @system @world
emerge busybox dhcpcd iproute2 vim
sed -ri 's/^#rc_sys=""/rc_sys="lxc"/' /etc/rc.conf
sed -ri 's/^([^#].*agetty.*)$/#\1/' /etc/inittab
rc-update add sshd default
rc-update del udev sysinit
rc-update add mdev sysinit
eselect news read
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

> /etc/resolv.conf

cat >> /etc/inittab <<END

# Start getty on /dev/console
c0:2345:respawn:/sbin/agetty 38400 console linux

# Clean container shutdown on SIGPWR
pf:12345:powerwait:/sbin/halt
END

rm -f /usr/portage/distfiles/*
EOF

run-configure
