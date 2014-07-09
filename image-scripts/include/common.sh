function cleanup {
	echo "Cleanup ..."
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
	chroot $INSTALL /tmp/configure.sh
	rm -f $CONFIGURE
}

function pack {
	echo "Packing template into $OUTPUT ..."
	pushd $INSTALL > /dev/null
	tar czf $OUTPUT .
	popd > /dev/null
}

