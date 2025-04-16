. "$IMAGEDIR/config.sh"
BASEURL=http://ftp.fi.muni.cz/pub/linux/fedora/linux/releases/$RELVER/Everything/x86_64/os
RELEASE="$BASEURL/Packages/f/fedora-release-server-$RELVER-25.noarch.rpm
$BASEURL/Packages/f/fedora-release-$RELVER-25.noarch.rpm
$BASEURL/Packages/f/fedora-release-common-$RELVER-25.noarch.rpm
$BASEURL/Packages/f/fedora-release-identity-basic-$RELVER-25.noarch.rpm"
EXTRAPKGS="@core vim man fedora-gpg-keys fedora-repos glibc-langpack-en"
REMOVEPKGS="plymouth"

. $INCLUDE/redhat-family.sh

bootstrap
configure-common

configure-redhat-common
configure-fedora
configure-fedora-nm-keyfiles
run-configure

