DISTNAME=gentoo
RELVER=13.0-$(date +%Y%m%d)
BASEURL=http://mirror.vpsfree.cz/gentoo


STAGE3BASEURL="${BASEURL}/releases/amd64/autobuilds"
STAGE3TARBALLURL="${STAGE3BASEURL}/$(curl "${STAGE3BASEURL}/latest-stage3-amd64.txt" | grep -o -m 1 -P '^\d+/stage3-amd64-\d+.tar.bz2')"
STAGE3TARBALL="$(basename $STAGE3TARBALLURL)"


wget -P $DOWNLOAD ${STAGE3TARBALLURL}{.CONTENTS,.DIGESTS,}

if ! (cd $DOWNLOAD; sed -rn '/# SHA512/ {N;p}' ${STAGE3TARBALL}.DIGESTS | sha512sum -c);
then
	echo "Stage 3 checksum wrong! Quitting."
	exit 1
fi

echo "Unpacking Stage3..."
tar xjpf ${DOWNLOAD}/${STAGE3TARBALL} -C $INSTALL

cp /etc/resolv.conf $INSTALL/etc/

cp "$BASEDIR"/files/cgroups-mount.initd "$INSTALL"/etc/init.d/cgroups-mount
chmod +x "$INSTALL"/etc/init.d/cgroups-mount

configure-append <<EOF
export PATH="/bin:/sbin:/usr/bin:$PATH"
EOF

configure-common

configure-append <<EOF
echo 'LANG="en_US.UTF-8"' >/etc/env.d/02locale
echo 'GENTOO_MIRRORS="$BASEURL/ http://ftp.fi.muni.cz/pub/linux/gentoo/"' >> /etc/portage/make.conf
echo "Europe/Prague" > /etc/timezone
cat >/etc/conf.d/net <<CONFDNET
postup() {
        [ \\\$IFACE == 'venet0' ] && ip -6 route add default dev venet0
}
CONFDNET
emerge-webrsync -v
sed -i 's/USE="bindist"/USE=""/' /etc/portage/make.conf
emerge --update --deep --newuse --with-bdeps=y --backtrack=120 @system @world
emerge iproute2
emerge vim
sed -ri 's/^#rc_sys=""/rc_sys="openvz"/' /etc/rc.conf
sed -ri 's/^([^#].*agetty.*)$/#\1/' /etc/inittab
rc-update add sshd default
rc-update add cgroups-mount boot
rc-update delete udev sysinit
eselect news read
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

> /etc/resolv.conf

cat >> /etc/inittab <<END
c0:2345:respawn:/sbin/agetty --noreset 38400 tty0

# Workaround for vzctl's set_console.sh
#1:2345:respawn:/sbin/agetty console 38400
#2:2345:respawn:/sbin/agetty tty2 38400
END

rm -f /usr/portage/distfiles/*
EOF

run-configure
