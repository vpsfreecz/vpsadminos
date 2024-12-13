. "$IMAGEDIR/config.sh"
POINTVER=10.0
RELEASE=https://mirror.stream.centos.org/10-stream/BaseOS/x86_64/os/Packages/centos-stream-release-${POINTVER}-3.el10.noarch.rpm
BASEURL=http://mirror.stream.centos.org/10-stream/BaseOS/x86_64/os/

# CentOS >8 does not seem to have an updates repo, so this variable is used to
# add AppStream repository just for the installation process.
UPDATES=http://mirror.stream.centos.org/10-stream/AppStream/x86_64/os/

GROUPNAME='core'
EXTRAPKGS='centos-stream-repos vim man'

. $INCLUDE/redhat-family.sh

bootstrap
configure-common
configure-redhat-common
configure-rhel-10
run-configure
