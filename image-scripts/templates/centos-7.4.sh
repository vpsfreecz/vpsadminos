DISTNAME=centos
RELVER=7.4
BUILD=1708
RELEASE=http://mirror.centos.org/centos/${RELVER}.${BUILD}/os/x86_64/Packages/centos-release-${RELVER//./-}.${BUILD}.el7.centos.x86_64.rpm
BASEURL=http://mirror.centos.org/centos/${RELVER}.${BUILD}/os/x86_64
UPDATES=http://mirror.centos.org/centos/${RELVER}.${BUILD}/updates/x86_64/
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
