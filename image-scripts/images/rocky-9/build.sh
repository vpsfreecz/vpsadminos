. "$IMAGEDIR/config.sh"
POINTVER=9.3
RELEASE=https://ftp.sh.cvut.cz/rocky/${POINTVER}/BaseOS/x86_64/os/Packages/r/rocky-release-${POINTVER}-1.1.el9.noarch.rpm
BASEURL=https://ftp.sh.cvut.cz/rocky/${POINTVER}/BaseOS/x86_64/os/

# CentOS 8 does not seem to have an updates repo, so this variable is used to
# add AppStream repository just for the installation process.
UPDATES=https://ftp.sh.cvut.cz/rocky/${POINTVER}/AppStream/x86_64/os/

GROUPNAME='core'
EXTRAPKGS='rocky-gpg-keys rocky-repos vim man'

. $INCLUDE/redhat-family.sh

bootstrap
configure-common
configure-redhat-common
configure-rhel-9
run-configure
set-initcmd "/sbin/init" "systemd.unified_cgroup_hierarchy=0"
