#!/bin/bash
require_cmd zypper

if [ "$SPIN" == "leap" ]; then
	REPOSITORY=http://download.opensuse.org/distribution/leap/$SPINVER/repo/oss/
	UPDATES=http://download.opensuse.org/update/leap/$SPINVER/oss/
elif [ "$SPIN" == "tumbleweed" ]; then
	REPOSITORY=http://download.opensuse.org/tumbleweed/repo/oss/
	UPDATES=http://download.opensuse.org/update/tumbleweed/
else
	fail "unsupported spin"
fi

EXTRAPKGS='vim iproute2 iputils net-tools procps less psmisc timezone aaa_base-extras openssh curl ca-certificates ca-certificates-mozilla wicked'

ZYPPER="zypper -v --root=$INSTALL --non-interactive --gpg-auto-import-keys "

do_bootstrap() ( # new subshell
	set -e
	$ZYPPER addrepo --refresh -g $REPOSITORY openSUSE-oss
	$ZYPPER addrepo --refresh -g $UPDATES openSUSE-updates
	$ZYPPER refresh
	$ZYPPER install --no-recommends aaa_base shadow patterns-base-base patterns-base-sw_management $EXTRAPKGS
)

function bootstrap {
	mount-chroot "$INSTALL"
	do_bootstrap
	rc=$?
	umount-chroot "$INSTALL"
	[ "$rc" != 0 ] && fail "bootstrap failed"
}

function configure-opensuse {
	configure-append <<EOF
[ ! -e /sbin/init ] && ln -sf /usr/lib/systemd/systemd /sbin/init
systemctl enable  wicked.service
usermod -L root

systemctl enable sshd.service

if [ -d /etc/ssh/sshd_config.d ] ; then
	cat <<EOT > /etc/ssh/sshd_config.d/vpsadminos.conf
PermitRootLogin yes
PasswordAuthentication yes
EOT
fi

systemctl mask systemd-modules-load.service
echo console >> /etc/securetty
sed -i 's/#DefaultTimeoutStartSec=90s/DefaultTimeoutStartSec=900s/' /etc/systemd/system.conf
echo "%_netsharedpath /sys:/proc" >> /etc/rpm/macros.vpsadminos
mkdir -p /var/log/journal

mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat <<EOT > /etc/systemd/system/systemd-udev-trigger.service.d/vpsadminos.conf
[Service]
ExecStart=
ExecStart=-udevadm trigger --subsystem-match=net --action=add
EOT
EOF
}
