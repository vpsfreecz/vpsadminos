DISTNAME=arch
RELVER=$(date +%Y%m%d)
BASEURL=https://mirror.vpsfree.cz/archlinux/iso/latest

bootstrap-arch() {
	# Find out the bootstrap archive's name from checksum list
	rx='archlinux-bootstrap-\d+\.\d+\.\d+-x86_64\.tar\.gz'
	curl "$BASEURL/sha1sums.txt" | grep -P "$rx" > "$DOWNLOAD/sha1sums.txt"
	bfile=$(grep -oP "$rx" "$DOWNLOAD/sha1sums.txt")

	# Download the bootstrap archive and verify checksum
	curl -o "$DOWNLOAD/$bfile" "$BASEURL/$bfile"
	if ! (cd "$DOWNLOAD" ; sha1sum -c sha1sums.txt) ; then
		echo "Bootstrap checksum wrong! Quitting."
		exit 1
	fi

	# Extract
	tar -xzf "$DOWNLOAD/$bfile" --preserve-permissions --preserve-order --numeric-owner \
		-C "$INSTALL"

	# Bootstrap the base system to $INSTALL/root.x86_64/mnt
	local BOOTSTRAP="$INSTALL/root.x86_64"
	local SETUP="/install.sh"

	sed -ri 's/^#(.*vpsfree\.cz.*)$/\1/' "$BOOTSTRAP/etc/pacman.d/mirrorlist"
	echo nameserver 8.8.8.8 > "$BOOTSTRAP/etc/resolv.conf"

	cat <<EOF > "$BOOTSTRAP/$SETUP"
#!/bin/bash

pacman-key --init
pacman-key --populate archlinux

pacstrap -dG /mnt base openssh
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
yes | pacman -Scc

# Newer glibc versions require kernel >= 3.2
pacman --noconfirm -U https://archive.archlinux.org/packages/g/glibc/glibc-2.25-7-x86_64.pkg.tar.xz

gpg-connect-agent --homedir /etc/pacman.d/gnupg "SCD KILLSCD" "SCD BYE" /bye
gpg-connect-agent --homedir /etc/pacman.d/gnupg killagent /bye

ln -s /usr/share/zoneinfo/Europe/Prague /etc/localtime
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#DefaultTimeoutStartSec=90s/DefaultTimeoutStartSec=900s/' /etc/systemd/system.conf
systemctl enable sshd
systemctl disable systemd-resolved
usermod -L root
sed -ri 's/^#( *IgnorePkg *=.*)$/\1 libsystemd systemd systemd-sysvcompat python2-systemd glibc/' /etc/pacman.conf

for i in systemd-journald systemd-logind; do
  echo "Creating systemd override file for \$i"
  mkdir /etc/systemd/system/\$i.service.d/
  cat > /etc/systemd/system/\$i.service.d/override.conf <<EOT
[Service]
SystemCallFilter=
MemoryDenyWriteExecute=no
EOT
done

echo > /etc/resolv.conf

EOF
}

bootstrap-arch
configure-arch
run-configure
