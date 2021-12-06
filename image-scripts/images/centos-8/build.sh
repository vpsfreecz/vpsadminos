. "$IMAGEDIR/config.sh"
POINTVER=8.5
BUILD=2111
RELEASE=http://mirror.centos.org/centos/${POINTVER}.${BUILD}/BaseOS/x86_64/os/Packages/centos-linux-release-${POINTVER}-1.${BUILD}.el8.noarch.rpm
BASEURL=http://mirror.centos.org/centos/${POINTVER}.${BUILD}/BaseOS/x86_64/os/

# CentOS 8 does not seem to have an updates repo, so this variable is used to
# add AppStream repository just for the installation process.
UPDATES=http://mirror.centos.org/centos/${POINTVER}.${BUILD}/AppStream/x86_64/os/

GROUPNAME='core'
EXTRAPKGS='centos-gpg-keys centos-linux-repos vim man'

. $INCLUDE/redhat-family.sh

bootstrap
configure-common
configure-redhat-common
configure-rhel-8
run-configure
