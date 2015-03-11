DISTNAME=centos
RELVER=7.0
BUILD=1406
RELVERPACK=2.3
RELEASE=http://mirror.hosting90.cz/centos/${RELVER}.${BUILD}/os/x86_64/Packages/centos-release-${RELVER//./-}.${BUILD}.el7.centos.${RELVERPACK}.x86_64.rpm
BASEURL=http://mirror.hosting90.cz/centos/${RELVER}.${BUILD}/os/x86_64
UPDATES=http://mirror.hosting90.cz/centos/${RELVER}.${BUILD}/updates/x86_64/
GROUPNAME='core'
EXTRAPKGS='vim'

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
