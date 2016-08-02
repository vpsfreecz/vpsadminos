DISTNAME=debian
RELVER=7
RELNAME=wheezy
BASEURL=http://ftp.cz.debian.org/debian

. $INCLUDE/debian.sh

bootstrap

configure-common
configure-debian

cat > $INSTALL/etc/apt/sources.list <<SOURCES
deb $BASEURL $RELNAME main
deb-src $BASEURL $RELNAME main

deb $BASEURL $RELNAME-updates main
deb-src $BASEURL $RELNAME-updates main

deb http://security.debian.org/ $RELNAME/updates main
deb-src http://security.debian.org/ $RELNAME/updates main
SOURCES

configure-append <<EOF
sed -i -e '/^[2-6]\:/ s/^#*/#/' /etc/inittab
sed -i 's/tty1/tty0/' /etc/inittab
EOF

run-configure
