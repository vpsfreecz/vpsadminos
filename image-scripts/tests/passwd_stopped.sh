# NixOS does not have /etc until the first start
if [ "$DISTNAME" == "nixos" ] || [ "$DISTNAME" == "guix" ] ; then
	osctl ct start $CTID || fail "unable to start"
	sleep 30
	osctl ct stop $CTID || fail "unable to stop"
fi
osctl ct passwd $CTID root suCHS3crET || fail "unable to set password"
