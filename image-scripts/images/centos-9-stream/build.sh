. "$IMAGEDIR/config.sh"
POINTVER=9.0
RELEASE=http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/Packages/centos-stream-release-${POINTVER}-5.el9.noarch.rpm
BASEURL=http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/

# CentOS >8 does not seem to have an updates repo, so this variable is used to
# add AppStream repository just for the installation process.
UPDATES=http://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/

GROUPNAME='core'
EXTRAPKGS='centos-stream-repos vim man'

. $INCLUDE/redhat-family.sh

bootstrap
configure-common
configure-redhat-common
configure-rhel-9
run-configure
set-initcmd "/sbin/init" "systemd.unified_cgroup_hierarchy=0"
