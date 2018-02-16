function mount-chroot {
	mount -t proc proc "$1/proc"
	mount -t sysfs sys "$1/sys"
	mount --bind /dev "$1/dev"
}

function umount-chroot {
	umount "$1/dev"
	umount "$1/sys"
	umount "$1/proc"
}

function do-chroot {
	mount-chroot "$1"
	chroot "$1" "$2"
	umount-chroot "$1"
}

function configure-append {
	cat >> $CONFIGURE
}

function configure-common {
	configure-append <<EOF
export PATH="/bin:/sbin:/usr/bin:$PATH"
rm -f /etc/mtab
ln -s /proc/mounts /etc/mtab
cp /usr/share/zoneinfo/Europe/Prague /etc/localtime
EOF
}

function run-configure {
	[ ! -f $CONFIGURE ] && touch $CONFIGURE
	chmod +x $CONFIGURE
		do-chroot "$INSTALL" /tmp/configure.sh
	rm -f $CONFIGURE
}

function pack {
	local TARBALL="$1"
	local SRCDIR="$2"

	echo "Packing template into $TARBALL"
	tar -czf "$TARBALL" -C "$SRCDIR" .
}

function dump_stream {
	local DATFILE="$1"
	local SNAPSHOT="$2"

	echo "Dumping stream into $DATFILE"
	zfs snapshot "$SNAPSHOT"
	zfs send "$SNAPSHOT" | gzip > "$DATFILE"
}

