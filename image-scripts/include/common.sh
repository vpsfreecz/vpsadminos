function cleanup {
	echo "Cleanup ..."
        rm -Rf $INSTALL
        rm -Rf $DOWNLOAD
}

trap cleanup SIGINT

function configure-append {
	cat >> $CONFIGURE
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

