DISTNAME=fedora
RELVER=22
BASEURL=http://ftp.fi.muni.cz/pub/linux/fedora/linux/releases/22/Everything/x86_64/os
UPDATES=http://ftp.fi.muni.cz/pub/linux/fedora/linux/updates/22/x86_64
RELEASE="$BASEURL/Packages/f/fedora-release-22-1.noarch.rpm 
	 $BASEURL/Packages/f/fedora-repos-22-1.noarch.rpm"
GROUPNAME="minimal install"
EXTRAPKGS="vim man"

. $INCLUDE/redhat-family.sh

bootstrap
configure-common

configure-redhat-common

configure-append <<EOF
systemctl disable NetworkManager.service
systemctl disable NetworkManager-wait-online.service
systemctl disable NetworkManager-dispatcher.service
systemctl enable  network.service
systemctl disable firewalld.service
EOF

run-configure
