function warn {
	>&2 echo "$@"
}

function cleanup {
	echo "Cleanup ..."
	rm -Rf $INSTALL
	rm -Rf $DOWNLOAD
}

trap cleanup SIGINT

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
	echo "Packing template into $OUTPUT ..."
	pushd $INSTALL > /dev/null
	tar czf $OUTPUT .
	popd > /dev/null
}

