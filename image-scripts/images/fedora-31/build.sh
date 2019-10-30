. "$IMAGEDIR/config.sh"
BASEURL=http://ftp.fi.muni.cz/pub/linux/fedora/linux/releases/$RELVER/Everything/x86_64/os
UPDATES=http://ftp.fi.muni.cz/pub/linux/fedora/linux/updates/$RELVER/x86_64
RELEASE="$BASEURL/Packages/f/fedora-release-$RELVER-1.noarch.rpm
	$BASEURL/Packages/f/fedora-repos-$RELVER-1.noarch.rpm"
GROUPNAME="minimal install"
EXTRAPKGS="vim man fedora-gpg-keys"
REMOVEPKGS="plymouth"

. $INCLUDE/redhat-family.sh

bootstrap
configure-common

configure-redhat-common

configure-append <<EOF
systemctl mask auditd.service
systemctl mask systemd-journald-audit.socket
systemctl mask firewalld.service
systemctl mask systemd-udev-trigger.service
systemctl mask proc-sys-fs-binfmt_misc.mount
systemctl disable tcsd.service
systemctl disable rdisc.service
systemctl disable systemd-bootchart.service
systemctl disable sssd.service

sed -i -e 's/^#PermitRootLogin\ prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config

cat <<EOT > /etc/NetworkManager/conf.d/vpsadminos.conf
[main]
plugins+=ifcfg-rh
rc-manager=file
EOT
EOF

run-configure
