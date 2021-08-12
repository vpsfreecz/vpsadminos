. "$IMAGEDIR/config.sh"
RELNAME=bullseye
BASEURL=http://ftp.cz.debian.org/debian

. "$INCLUDE/debian.sh"

bootstrap

configure-common
configure-debian

cat > "$INSTALL/etc/apt/sources.list" <<SOURCES
deb $BASEURL $RELNAME main
deb-src $BASEURL $RELNAME main

deb $BASEURL $RELNAME-updates main
deb-src $BASEURL $RELNAME-updates main

deb http://security.debian.org/ $RELNAME/updates main
deb-src http://security.debian.org/ $RELNAME/updates main
SOURCES

configure-append <<EOF
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
EOF

run-configure
