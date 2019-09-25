. "$IMAGEDIR/config.sh"
POINTVER=8.0
BUILD=1905
RELEASE=http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/Packages/centos-release-stream-${POINTVER}-0.${BUILD}.0.9.el8.x86_64.rpm
BASEURL=http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/

# CentOS 8 does not seem to have an updates repo, so this variable is used to
# add AppStream repository just for the installation process.
UPDATES=http://mirror.centos.org/centos/8-stream/AppStream/x86_64/os/

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
