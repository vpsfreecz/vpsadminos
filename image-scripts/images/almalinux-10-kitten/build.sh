. "$IMAGEDIR/config.sh"
POINTVER=10
RELEASE=https://kitten.repo.almalinux.org/${POINTVER}-kitten/BaseOS/x86_64/os/Packages/almalinux-kitten-release-${POINTVER}.0-0.21.el10.2.x86_64.rpm
BASEURL=https://kitten.repo.almalinux.org/${POINTVER}-kitten/BaseOS/x86_64/os/

# CentOS 8 does not seem to have an updates repo, so this variable is used to
# add AppStream repository just for the installation process.
UPDATES=https://kitten.repo.almalinux.org/${POINTVER}-kitten/AppStream/x86_64/os/

GROUPNAME='core'
EXTRAPKGS='almalinux-kitten-repos vim man'

. $INCLUDE/redhat-family.sh

bootstrap
configure-common
configure-redhat-common
configure-rhel-10
run-configure
set-initcmd "/sbin/init" "systemd.unified_cgroup_hierarchy=0"
