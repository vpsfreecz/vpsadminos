function umount_install {
        umount $INSTALL/dev
        umount $INSTALL/sys
        umount $INSTALL/proc
}

function cleanup {
	echo "Cleanup ..."
        umount_install
        rm -Rf $INSTALL
        rm -Rf $DOWNLOAD
}

trap cleanup SIGINT

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
        mount -t proc proc $INSTALL/proc
        mount -t sysfs sys $INSTALL/sys
        mount --bind /dev $INSTALL/dev
	chroot $INSTALL /tmp/configure.sh
        umount_install
	rm -f $CONFIGURE
}

function pack {
	echo "Packing template into $OUTPUT ..."
	pushd $INSTALL > /dev/null
	tar czf $OUTPUT .
	popd > /dev/null
}

