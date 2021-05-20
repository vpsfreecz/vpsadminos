function can_set {
	local ns=$@
	osctl ct set dns-resolver $CTID $ns
}

function has_nameserver {
	local ns="$1"
	osctl ct exec $CTID cat /etc/resolv.conf | grep -qx "nameserver $ns"
	if [ "$?" != "0" ] ; then
		echo "nameserver '$ns' not found in /etc/resolv.conf"
		return 1
	fi
}

function has_not_nameserver {
	local ns="$1"
	osctl ct exec $CTID cat /etc/resolv.conf | grep -qx "nameserver $ns"
	if [ "$?" == "0" ] ; then
		echo "nameserver '$ns' found in /etc/resolv.conf"
		return 1
	fi
}

if [ "$DISTNAME" == "nixos" ] ; then
	# DNS resolvers on NixOS cannot be changed from the outside using osctl
	exit 0
fi

osctl ct stop $CTID
can_set "1.1.1.1" || fail "unable to set dns resolvers when stopped"
osctl ct start $CTID
has_nameserver "1.1.1.1" || fail "dns resolver isn't set after start"
sleep 30 # make sure that nothing from inside the vps will override it
has_nameserver "1.1.1.1" || fail "dns resolver lost after start"

can_set "8.8.8.8" || fail "unable to set dns resolver when started"
has_nameserver "8.8.8.8" || fail "dns resolver isn't set at runtime"
has_not_nameserver "1.1.1.1" || fail "replaced dns resolver wasn't removed"
osctl ct restart $CTID || fail "unable to restart"
has_nameserver "8.8.8.8" || fail "dns resolvers aren't persisted"

can_set 1.1.1.1 8.8.8.8 || fail "unable to set multiple dns resolvers"
has_nameserver "1.1.1.1" || fail "dns resolver 1.1.1.1 not found"
has_nameserver "8.8.8.8" || fail "dns resolver 8.8.8.8 not found"
