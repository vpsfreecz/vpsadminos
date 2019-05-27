. "$TEMPLATEDIR/config.sh"
RELNAME=ascii
BASEURL=http://auto.mirror.devuan.org/merged

. $INCLUDE/debian.sh

bootstrap

configure-common

configure-append <<EOF
apt-get install -y --force-yes devuan-keyring
EOF

configure-debian

cat > $INSTALL/etc/apt/sources.list <<SOURCES
deb $BASEURL $RELNAME main
deb-src $BASEURL $RELNAME main

deb $BASEURL $RELNAME-updates main
deb-src $BASEURL $RELNAME-updates main

deb $BASEURL $RELNAME-security main
deb-src $BASEURL $RELNAME-security main
SOURCES

configure-append <<EOF
sed -i 's|pf::powerwait:/etc/init.d/powerfail start|pf::powerwait:/sbin/halt|' /etc/inittab
sed -ri 's/^([^#].*getty.*)$/#\1/' /etc/inittab

cat >> /etc/inittab <<END

# Start getty on /dev/console
c0:2345:respawn:/sbin/agetty --noreset 38400 console
END

sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
EOF

run-configure
