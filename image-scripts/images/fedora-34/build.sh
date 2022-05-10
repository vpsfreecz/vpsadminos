. "$IMAGEDIR/config.sh"
BASEURL=http://ftp.fi.muni.cz/pub/linux/fedora/linux/releases/$RELVER/Everything/x86_64/os
RELEASE="$BASEURL/Packages/f/fedora-release-server-$RELVER-1.noarch.rpm"
GROUPNAME="minimal install"
EXTRAPKGS="vim man fedora-gpg-keys"
REMOVEPKGS="plymouth"

. $INCLUDE/redhat-family.sh

bootstrap
configure-common

configure-redhat-common
configure-fedora
configure-fedora-nm-initscripts
run-configure

set-initcmd "/sbin/init" "systemd.unified_cgroup_hierarchy=0"
