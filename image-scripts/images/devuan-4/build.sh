. "$IMAGEDIR/config.sh"
RELNAME=chimaera
BASEURL=http://deb.devuan.org/merged

. $INCLUDE/devuan.sh

bootstrap

cat > $INSTALL/etc/apt/sources.list <<SOURCES
deb $BASEURL $RELNAME main
deb-src $BASEURL $RELNAME main

deb $BASEURL $RELNAME-updates main
deb-src $BASEURL $RELNAME-updates main

deb $BASEURL $RELNAME-security main
deb-src $BASEURL $RELNAME-security main
SOURCES

cp "$IMAGEDIR"/cgroups-mount.initscript "$INSTALL"/etc/init.d/cgroups-mount
chmod +x "$INSTALL"/etc/init.d/cgroups-mount

configure-common

configure-devuan-append <<EOF
update-rc.d cgroups-mount defaults
EOF

configure-devuan

run-configure
