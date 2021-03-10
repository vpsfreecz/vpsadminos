. "$IMAGEDIR/config.sh"
POINTVER=7.9
BUILD=2009
RELEASE=http://mirror.centos.org/centos/${POINTVER}.${BUILD}/os/x86_64/Packages/centos-release-${POINTVER//./-}.${BUILD}.0.el7.centos.x86_64.rpm
BASEURL=http://mirror.centos.org/centos/${POINTVER}.${BUILD}/os/x86_64
UPDATES=http://mirror.centos.org/centos/${POINTVER}.${BUILD}/updates/x86_64/
GROUPNAME='core'
EXTRAPKGS='vim man'

. $INCLUDE/redhat-family.sh

bootstrap
configure-common

configure-redhat-common

configure-append <<EOF
/usr/bin/systemctl disable NetworkManager.service
/usr/bin/systemctl disable NetworkManager-wait-online.service
/usr/bin/systemctl disable NetworkManager-dispatcher.service
/usr/sbin/chkconfig network on
/usr/bin/systemctl disable firewalld.service
EOF

run-configure
