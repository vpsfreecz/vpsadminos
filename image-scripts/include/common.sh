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
	local status=0
	local proc_mounted=0
	local sys_mounted=0
	local dev_mounted=0
	local dev_detached=0

	mkdir -p "$1/proc" "$1/sys" "$1/dev" || return $?

	mount -t proc proc "$1/proc" || status=$?
	if [ "$status" -eq 0 ] ; then
		proc_mounted=1
		mount -t sysfs sys "$1/sys" || status=$?
	fi
	if [ "$status" -eq 0 ] ; then
		sys_mounted=1
		mount --rbind /dev "$1/dev" || status=$?
	fi
	if [ "$status" -eq 0 ] ; then
		dev_mounted=1
		mount --make-rslave "$1/dev" || status=$?
	fi

	if [ "$status" -ne 0 ] ; then
		if [ "$dev_mounted" -eq 1 ] ; then
			# If make-rslave failed, recursive unmounts could propagate through
			# the still-shared bind back to /dev. Make the clone private before
			# detaching it. If that also fails, namespace teardown is safer than
			# attempting an unprotected recursive unmount.
			if mount --make-rprivate "$1/dev" ; then
				dev_detached=1
			fi
			if [ "$dev_detached" -eq 1 ] ; then
				umount -R "$1/dev" || true
			fi
		fi
		if [ "$sys_mounted" -eq 1 ] ; then
			umount "$1/sys" || true
		fi
		if [ "$proc_mounted" -eq 1 ] ; then
			umount "$1/proc" || true
		fi
		return "$status"
	fi

	return 0
}

function umount-chroot {
	local status=0

	umount -R "$1/dev" || status=$?
	umount "$1/sys" || status=$?
	umount "$1/proc" || status=$?

	return "$status"
}

function do-chroot {
	local chroot_status=0
	local cleanup_status=0

	mount-chroot "$1" || return $?
	chroot "$1" "$2" || chroot_status=$?
	umount-chroot "$1" || cleanup_status=$?

	[ "$chroot_status" -ne 0 ] && return "$chroot_status"
	return "$cleanup_status"
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

if [ -h /etc/localtime ] ; then
  ln -sf /usr/share/zoneinfo/Europe/Prague /etc/localtime
else
  cp /usr/share/zoneinfo/Europe/Prague /etc/localtime
fi
EOF
}

function run-configure {
	local configure_status=0
	local cleanup_status=0

	if [ ! -f "$CONFIGURE" ] ; then
		touch "$CONFIGURE" || configure_status=$?
	fi

	if [ "$configure_status" -eq 0 ] ; then
		chmod +x "$CONFIGURE" || configure_status=$?
	fi

	if [ "$configure_status" -eq 0 ] ; then
		do-chroot "$INSTALL" /tmp/configure.sh || configure_status=$?
	fi

	rm -f "$CONFIGURE" || cleanup_status=$?

	[ "$configure_status" -ne 0 ] && return "$configure_status"
	return "$cleanup_status"
}

function set-initcmd {
	INITCMD="- \"$1\""
	shift

	while [ $# -gt 0 ] ; do
		INITCMD="$INITCMD\n- \"$1\""
		shift
	done
}
