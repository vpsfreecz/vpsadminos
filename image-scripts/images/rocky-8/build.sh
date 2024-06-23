. "$IMAGEDIR/config.sh"
POINTVER=8.10
RELEASE=https://ftp.linux.cz/pub/linux/rocky/${POINTVER}/BaseOS/x86_64/os/Packages/r/rocky-release-${POINTVER}-1.9.el8.noarch.rpm
BASEURL=https://ftp.linux.cz/pub/linux/rocky/${POINTVER}/BaseOS/x86_64/os/

# CentOS 8 does not seem to have an updates repo, so this variable is used to
# add AppStream repository just for the installation process.
UPDATES=https://ftp.linux.cz/pub/linux/rocky/${POINTVER}/AppStream/x86_64/os/

GROUPNAME='core'
EXTRAPKGS='rocky-gpg-keys rocky-repos vim man'

. $INCLUDE/redhat-family.sh

bootstrap
configure-common
configure-redhat-common
configure-rhel-8
run-configure
