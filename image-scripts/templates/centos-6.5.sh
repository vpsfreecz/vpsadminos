DISTNAME=centos
RELVER=6.5
RELVERPACK=11.1
RELEASE=http://mirror.hosting90.cz/centos/${RELVER}/os/x86_64/Packages/centos-release-${RELVER//./-}.el6.centos.{$RELVERPACK}.x86_64.rpm
BASEURL=http://mirror.hosting90.cz/centos/${RELVER}/os/x86_64
UPDATES=http://mirror.hosting90.cz/centos/${RELVER}/updates/x86_64/
GROUPNAME='core'
EXTRAPKGS='vim openssh-clients'

. $INCLUDE/redhat-family.sh

bootstrap
configure-common

configure-redhat-common

configure-append <<EOF
/sbin/chkconfig network on
/sbin/chkconfig iptables off
sed -i "s/\[1\-6\]/\[0\-6\]/" /etc/init/start-ttys.conf
EOF

run-configure
