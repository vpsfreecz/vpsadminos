DISTNAME=centos
RELVER=6.6
RELVERPACK=12.2
RELEASE=http://mirror.hosting90.cz/centos/${RELVER}/os/x86_64/Packages/centos-release-${RELVER//./-}.el6.centos.{$RELVERPACK}.x86_64.rpm
BASEURL=http://mirror.hosting90.cz/centos/${RELVER}/os/x86_64
UPDATES=http://mirror.hosting90.cz/centos/${RELVER}/updates/x86_64/
GROUPNAME="core"
EXTRAPKGS="openssh-clients man"

. $INCLUDE/redhat-family.sh

bootstrap
configure-common

cat > $INSTALL/etc/fstab <<SOURCES
none    /dev/pts        devpts  rw,gid=5,mode=620       0       0
none    /dev/shm        tmpfs   defaults                0       0
SOURCES

configure-redhat-common

configure-append <<EOF
/sbin/chkconfig network on
/sbin/chkconfig iptables off
sed -i "s/\[1\-6\]/\[0\-6\]/" /etc/init/start-ttys.conf
EOF

run-configure
