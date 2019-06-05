. "$TEMPLATEDIR/config.sh"
POINTVER=6.10
POINTVERPACK=12.3
RELEASE=http://mirror.hosting90.cz/centos/${POINTVER}/os/x86_64/Packages/centos-release-${POINTVER//./-}.el6.centos.{$POINTVERPACK}.x86_64.rpm
BASEURL=http://mirror.hosting90.cz/centos/${POINTVER}/os/x86_64
UPDATES=http://mirror.hosting90.cz/centos/${POINTVER}/updates/x86_64/
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

cat <<EOT > /etc/init/shutdown.conf
description "Trigger an immediate shutdown on SIGPWR"
start on power-status-changed

task
exec shutdown -h now "SIGPWR received"
EOT
EOF

run-configure
