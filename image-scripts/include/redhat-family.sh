#!/bin/bash

. $BASEDIR/include/common.sh

if [ "$DISTNAME" == "fedora" ]; then
	require_cmd dnf

	YUM="dnf -c $DOWNLOAD/yum.conf --installroot=$INSTALL \
		--disablerepo=* --enablerepo=install-$DISTNAME \
		-y"
	YUM_GROUPINSTALL="$YUM group install"
else
	require_cmd yum

	YUM="yum -c $DOWNLOAD/yum.conf --installroot=$INSTALL \
		--disablerepo=* --enablerepo=install-$DISTNAME \
		--enablerepo=install-$DISTNAME-updates -y"
	YUM_GROUPINSTALL="$YUM groupinstall"
fi

function bootstrap {
	mkdir -p ${INSTALL}/var/lib/rpm
	rpm --root $INSTALL --initdb

	nrpm=0
	for rpm in $RELEASE; do
		nrpm=$(( $nrpm + 1 ))
		echo "Downloading #${nrpm} $rpm"
		curl -o $DOWNLOAD/release${nrpm}.rpm $rpm || fail "unable to download $rpm"
		rpm --root $INSTALL --nodeps -ivh $DOWNLOAD/release${nrpm}.rpm \
			|| fail "unable to install $rpm"
	done

	cat > $DOWNLOAD/yum.conf << EOF
[main]
cachedir=$DOWNLOAD/var/cache/yum/\$basearch/\$releasever
keepcache=0
debuglevel=2
logfile=$DOWNLOAD/var/log/yum.log
exactarch=1
obsoletes=1
gpgcheck=1
plugins=1
installonly_limit=3

[install-$DISTNAME]
name=install-$DISTNAME
enabled=1
gpgcheck=0
baseurl=$BASEURL

[install-$DISTNAME-updates]
name=install-$DISTNAME-updates
enabled=1
gpgcheck=0
baseurl=$UPDATES
EOF

	mkdir -p $DOWNLOAD/var/cache/yum
	mkdir -p $DOWNLOAD/var/log

	$YUM_GROUPINSTALL "$GROUPNAME"
	for rpm in $EXTRAPKGS; do
		$YUM install $rpm
	done

	for rpm in $REMOVEPKGS; do
		$YUM erase $rpm
	done
	$YUM clean all

}

function configure-redhat-common {
	configure-append <<EOF
usermod -L root
rm -f /etc/ssh/ssh_host_*

if [ -f /etc/systemd/system.conf ] ; then
	sed -i 's/#DefaultTimeoutStartSec=90s/DefaultTimeoutStartSec=900s/' /etc/systemd/system.conf
fi

if [ -d /etc/systemd ] ; then
  echo > /etc/machine-id
  mkdir -p /var/log/journal
  systemctl mask var-lib-nfs-rpc_pipefs.mount
  systemctl mask rngd-wake-threshold.service
fi

echo "%_netsharedpath /sys:/proc" >> /etc/rpm/macros.vpsadminos
EOF
}

function configure-fedora {
	configure-append <<EOF
rm -f /etc/resolv.conf
echo nameserver 8.8.8.8 > /etc/resolv.conf
dnf -y update
dnf -y clean all
> /etc/resolv.conf

systemctl mask auditd.service
systemctl mask systemd-journald-audit.socket
systemctl mask firewalld.service
systemctl mask proc-sys-fs-binfmt_misc.mount
systemctl mask sys-kernel-debug.mount
systemctl disable tcsd.service
systemctl disable rdisc.service
systemctl disable systemd-networkd.service
systemctl disable systemd-resolved.service
systemctl disable sssd.service
systemctl disable sshd.service

mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat <<EOT > /etc/systemd/system/systemd-udev-trigger.service.d/vpsadminos.conf
[Service]
ExecStart=
ExecStart=-udevadm trigger --subsystem-match=net --action=add
EOT

sed -i -e 's/^#PermitRootLogin\ prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config

cat <<EOT > /etc/NetworkManager/conf.d/vpsadminos.conf
[main]
dns=none
plugins+=ifcfg-rh
rc-manager=file
EOT
EOF
}
