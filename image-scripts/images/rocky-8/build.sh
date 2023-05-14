. "$IMAGEDIR/config.sh"
POINTVER=8.7
RELEASE=https://download.rockylinux.org/pub/rocky/${POINTVER}/BaseOS/x86_64/os/Packages/r/rocky-release-${POINTVER}-1.2.el8.noarch.rpm
BASEURL=https://download.rockylinux.org/pub/rocky/${POINTVER}/BaseOS/x86_64/os/

# CentOS 8 does not seem to have an updates repo, so this variable is used to
# add AppStream repository just for the installation process.
UPDATES=https://download.rockylinux.org/pub/rocky/${POINTVER}/AppStream/x86_64/os/

GROUPNAME='core'
EXTRAPKGS='rocky-gpg-keys rocky-repos vim man'

. $INCLUDE/redhat-family.sh

bootstrap
configure-common
configure-redhat-common
configure-rhel-8
run-configure
