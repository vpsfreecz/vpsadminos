DISTNAME=centos
RELVER=6.9
RELVERPACK=12.3
RELEASE=http://mirror.hosting90.cz/centos/${RELVER}/os/x86_64/Packages/centos-release-${RELVER//./-}.el6.centos.{$RELVERPACK}.x86_64.rpm
BASEURL=http://mirror.hosting90.cz/centos/${RELVER}/os/x86_64
UPDATES=http://mirror.hosting90.cz/centos/${RELVER}/updates/x86_64/
GROUPNAME="core"
EXTRAPKGS="openssh-clients man"

. $INCLUDE/redhat-family.sh

bootstrap
configure-common
configure-redhat-common

configure-append <<EOF
echo > /etc/fstab
/sbin/chkconfig network on
/sbin/chkconfig iptables off
sed -i "s/\[1\-6\]/\[0\-6\]/" /etc/init/start-ttys.conf
EOF

run-configure
