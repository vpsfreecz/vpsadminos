DISTNAME=devuan
RELVER=2.0
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
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
EOF

run-configure
