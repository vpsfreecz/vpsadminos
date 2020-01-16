. "$IMAGEDIR/config.sh"
POINTVER=8.1
BUILD=1911
RELEASE=http://mirror.centos.org/centos/${POINTVER}.${BUILD}/BaseOS/x86_64/os/Packages/centos-release-${POINTVER}-1.${BUILD}.0.8.el8.x86_64.rpm
BASEURL=http://mirror.centos.org/centos/${POINTVER}.${BUILD}/BaseOS/x86_64/os/

# CentOS 8 does not seem to have an updates repo, so this variable is used to
# add AppStream repository just for the installation process.
UPDATES=http://mirror.centos.org/centos/${POINTVER}.${BUILD}/AppStream/x86_64/os/

GROUPNAME='core'
EXTRAPKGS='vim man'

. $INCLUDE/redhat-family.sh

bootstrap
configure-common

configure-redhat-common

configure-append <<EOF
/usr/bin/systemctl disable firewalld.service
/usr/bin/systemctl mask auditd.service
/usr/bin/systemctl mask kdump.service
/usr/bin/systemctl mask plymouth-start.service
/usr/bin/systemctl mask tuned.service

cat <<EOT > /etc/NetworkManager/conf.d/vpsadminos.conf
[main]
plugins+=ifcfg-rh
rc-manager=file
configure-and-quit=true
EOT
EOF

run-configure
