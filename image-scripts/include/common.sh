function require_cmd {
	for cmd in $@ ; do
		command -v "$cmd" > /dev/null
		[ $? == 0 ] && continue

		echo "$cmd not found in PATH"
		exit 1
	done
}

function warn {
	>&2 echo "$@"
}

function fail {
	warn "$@"
	exit 1
}

function mount-chroot {
	mkdir -p "$1/proc" "$1/sys" "$1/dev"
	mount -t proc proc "$1/proc"
	mount -t sysfs sys "$1/sys"
	mount --rbind /dev "$1/dev"
	mount --make-rslave "$1/dev"
}

function umount-chroot {
	umount -R "$1/dev"
	umount "$1/sys"
	umount "$1/proc"
}

function do-chroot {
	mount-chroot "$1"
	chroot "$1" "$2"
	umount-chroot "$1"
}

function configure-shebang {
	local shebang="$1"

	if [ -f "$CONFIGURE" ] ; then
		echo "$shebang" > "$CONFIGURE.shebang"
		cat "$CONFIGURE" >>  "$CONFIGURE.shebang"
		mv "$CONFIGURE.shebang" "$CONFIGURE"
	else
		echo "$shebang" > "$CONFIGURE"
	fi
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

function set-initcmd {
	INITCMD="- \"$1\""
	shift

	while [ $# -gt 0 ] ; do
		INITCMD="$INITCMD\n- \"$1\""
		shift
	done
}

