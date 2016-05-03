DISTNAME=gentoo
RELVER=13.0
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
emerge iproute2
emerge vim
sed -ri 's/^#rc_sys=""/rc_sys="openvz"/' /etc/rc.conf
sed -ri 's/^([^#].*agetty.*)$/#\1/' /etc/inittab
rc-update add sshd default
rc-update delete udev sysinit
rc-update delete udev-mount sysinit

> /etc/resolv.conf
echo "c0:2345:respawn:/sbin/agetty --noreset 38400 tty0" >> /etc/inittab
EOF

run-configure
