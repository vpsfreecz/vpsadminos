function can_set {
	local hostname="$1"
	osctl ct set hostname $CTID "$hostname"
}

function hostname_is {
	local hostname="$1"
	local real="$(osctl ct exec $CTID hostname)"
	if [ "$hostname" != "$real" ] ; then
		echo "hostname mismatch: expected '$hostname', is '$real'"
		return 1
	fi
}

if [ "$DISTNAME" == "nixos" ] ; then
	# Hostname on NixOS cannot be changed from the outside using osctl
	exit 0
fi

osctl ct stop $CTID
can_set "superhost" || fail "unable to set hostname when stopped"
osctl ct start $CTID
hostname_is "superhost" || fail "hostname isn't set after start"
can_set "megahost" || fail "unable to set hostname when started"
hostname_is "megahost" || fail "hostname isn't set at runtime"
osctl ct restart $CTID || fail "unable to restart"
hostname_is "megahost" || fail "hostname isn't persisted"
