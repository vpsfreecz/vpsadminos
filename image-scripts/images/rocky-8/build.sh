. "$IMAGEDIR/config.sh"
POINTVER=8.4
RELEASE=https://download.rockylinux.org/pub/rocky/${POINTVER}/BaseOS/x86_64/os/Packages/rocky-release-${POINTVER}-26.el8.noarch.rpm
BASEURL=https://download.rockylinux.org/pub/rocky/${POINTVER}/BaseOS/x86_64/os/

# CentOS 8 does not seem to have an updates repo, so this variable is used to
# add AppStream repository just for the installation process.
UPDATES=https://download.rockylinux.org/pub/rocky/${POINTVER}/AppStream/x86_64/os/

GROUPNAME='core'
EXTRAPKGS='rocky-gpg-keys rocky-repos vim man'

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
