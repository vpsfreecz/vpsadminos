. "$IMAGEDIR/config.sh"
POINTVER=9.0
RELEASE=http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/Packages/centos-stream-release-${POINTVER}-2.el9.noarch.rpm
BASEURL=http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/

# CentOS >8 does not seem to have an updates repo, so this variable is used to
# add AppStream repository just for the installation process.
UPDATES=http://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/

GROUPNAME='core'
EXTRAPKGS='centos-stream-repos vim man'

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
dns=none
plugins+=ifcfg-rh
rc-manager=file
configure-and-quit=true
EOT
EOF

run-configure
set-initcmd "/sbin/init" "systemd.unified_cgroup_hierarchy=0"
