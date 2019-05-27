. "$TEMPLATEDIR/config.sh"
BASEURL=http://ftp.fi.muni.cz/pub/linux/fedora/linux/releases/$RELVER/Everything/x86_64/os
UPDATES=http://ftp.fi.muni.cz/pub/linux/fedora/linux/updates/$RELVER/x86_64
RELEASE="$BASEURL/Packages/f/fedora-release-$RELVER-1.noarch.rpm
	$BASEURL/Packages/f/fedora-repos-$RELVER-1.noarch.rpm"
GROUPNAME="minimal install"
EXTRAPKGS="network-scripts vim man fedora-gpg-keys"
REMOVEPKGS="plymouth"

. $INCLUDE/redhat-family.sh

bootstrap
configure-common

configure-redhat-common

configure-append <<EOF
systemctl mask NetworkManager.service
systemctl mask NetworkManager-wait-online.service
systemctl mask NetworkManager-dispatcher.service
systemctl enable network.service
systemctl mask firewalld.service
EOF

run-configure
