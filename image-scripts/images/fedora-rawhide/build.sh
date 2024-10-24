. "$IMAGEDIR/config.sh"
RAWHIDE_RELVER=42-0.6
BASEURL=http://ftp.fi.muni.cz/pub/linux/fedora/linux/development/rawhide/Everything/x86_64/os
RELEASE="$BASEURL/Packages/f/fedora-release-server-$RAWHIDE_RELVER.noarch.rpm
$BASEURL/Packages/f/fedora-release-$RAWHIDE_RELVER.noarch.rpm
$BASEURL/Packages/f/fedora-release-common-$RAWHIDE_RELVER.noarch.rpm
$BASEURL/Packages/f/fedora-release-identity-basic-$RAWHIDE_RELVER.noarch.rpm"
EXTRAPKGS="@core vim man fedora-gpg-keys fedora-repos glibc-langpack-en"
REMOVEPKGS="plymouth"

. $INCLUDE/redhat-family.sh

bootstrap
configure-common

configure-redhat-common
configure-fedora
configure-fedora-nm-keyfiles
run-configure

set-initcmd "/sbin/init" "systemd.unified_cgroup_hierarchy=0"
