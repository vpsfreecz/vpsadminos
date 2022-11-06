. "$IMAGEDIR"/config.sh
BASEURL=https://mirror.vpsfree.cz/archlinux/iso/latest

require_cmd curl

bootstrap-arch() {
	# Find out the bootstrap archive's name from checksum list
	rx='archlinux-bootstrap-\d+\.\d+\.\d+-x86_64\.tar\.gz'
	curl "$BASEURL/sha256sums.txt" | grep -P "$rx" > "$DOWNLOAD/sha256sums.txt"
	bfile=$(grep -oP "$rx" "$DOWNLOAD/sha256sums.txt")

	# Download the bootstrap archive and verify checksum
	curl -o "$DOWNLOAD/$bfile" "$BASEURL/$bfile"
	if ! (cd "$DOWNLOAD" ; sha256sum -c sha256sums.txt) ; then
		echo "Bootstrap checksum wrong! Quitting."
		exit 1
	fi

	# Extract
	tar -xzf "$DOWNLOAD/$bfile" --preserve-permissions --preserve-order --numeric-owner \
		-C "$INSTALL"

	# Bootstrap the base system to $INSTALL/root.x86_64/mnt
	local BOOTSTRAP="$INSTALL/root.x86_64"
	local SETUP="/install.sh"

	sed -i 's/CheckSpace/#CheckSpace/' "$BOOTSTRAP/etc/pacman.conf"
	sed -ri 's/^#(.*vpsfree\.cz.*)$/\1/' "$BOOTSTRAP/etc/pacman.d/mirrorlist"
	echo nameserver 8.8.8.8 > "$BOOTSTRAP/etc/resolv.conf"

	# pacstrap tries to mount /dev as devtmpfs, which is not possible in
	# an unprivileged container. We have to mount it as tmpfs and mknod
	# devices and create directories before mounting devpts and shm.
	cat <<'EOF' | patch "$BOOTSTRAP/bin/pacstrap"
101,103c101,109
<   chroot_add_mount udev "$1/dev" -t devtmpfs -o mode=0755,nosuid &&
<   chroot_add_mount devpts "$1/dev/pts" -t devpts -o mode=0620,gid=5,nosuid,noexec &&
<   chroot_add_mount shm "$1/dev/shm" -t tmpfs -o mode=1777,nosuid,nodev &&
---
>   chroot_add_mount udev "$1/dev" -t tmpfs -o mode=0755,nosuid &&
>   mknod "$1/dev/null" c 1 3 &&
>   mknod "$1/dev/zero" c 1 5 &&
>   mknod "$1/dev/full" c 1 7 &&
>   mknod "$1/dev/random" c 1 8 &&
>   mknod "$1/dev/urandom" c 1 9 &&
>   mknod "$1/dev/tty" c 5 0 &&
>   mkdir "$1/dev/pts" && chroot_add_mount devpts "$1/dev/pts" -t devpts -o mode=0620,gid=5,nosuid,noexec &&
>   mkdir "$1/dev/shm" && chroot_add_mount shm "$1/dev/shm" -t tmpfs -o mode=1777,nosuid,nodev &&
EOF

	cat <<EOF > "$BOOTSTRAP/$SETUP"
#!/bin/bash

mknod /dev/random c 1 8
mknod /dev/urandom c 1 9

pacman-key --init
pacman-key --populate archlinux

pacstrap -dG /mnt base openssh dhcpcd inetutils vim

gpg-connect-agent --homedir /etc/pacman.d/gnupg "SCD KILLSCD" "SCD BYE" /bye
gpg-connect-agent --homedir /etc/pacman.d/gnupg killagent /bye
EOF

	chmod +x "$BOOTSTRAP/$SETUP"
	do-chroot "$BOOTSTRAP" "$SETUP"

	# Replace bootstrap with the base system
	mv "$BOOTSTRAP"/mnt/* "$INSTALL/"
	rm -rf "$BOOTSTRAP"
}

configure-arch() {
	configure-append <<EOF
cat <<EOT > /etc/resolv.conf
$(cat /etc/resolv.conf)
EOT

cat >> /etc/fstab <<EOT
devpts       /dev/pts        devpts  gid=5,mode=620    0       0
tmpfs        /tmp            tmpfs   nodev,nosuid      0       0
EOT

pacman-key --init
pacman-key --populate archlinux
pacman -Rns --noconfirm linux
pacman -Scc --noconfirm

gpg-connect-agent --homedir /etc/pacman.d/gnupg "SCD KILLSCD" "SCD BYE" /bye
gpg-connect-agent --homedir /etc/pacman.d/gnupg killagent /bye

ln -s /usr/share/zoneinfo/Europe/Prague /etc/localtime
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#DefaultTimeoutStartSec=90s/DefaultTimeoutStartSec=900s/' /etc/systemd/system.conf

systemctl enable sshd
systemctl disable systemd-resolved
systemctl enable systemd-networkd

mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat <<EOT > /etc/systemd/system/systemd-udev-trigger.service.d/vpsadminos.conf
[Service]
ExecStart=
ExecStart=-udevadm trigger --subsystem-match=net --action=add
EOT

mkdir -p /var/log/journal
usermod -L root

echo > /etc/resolv.conf

EOF
}

bootstrap-arch
configure-arch
run-configure
set-initcmd "/sbin/init" "systemd.unified_cgroup_hierarchy=0"
