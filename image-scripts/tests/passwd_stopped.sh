# NixOS and Guix do not have /etc until the first start
if [ "$DISTNAME" == "nixos" ] || [ "$DISTNAME" == "guix" ] ; then
	osctl ct start $CTID || fail "unable to start"
	sleep 30

	# shepherd in guix is not reliable, it sometimes hangs on graceful shutdown
	if [ "$DISTNAME" == "guix" ] ; then
		osctl ct stop --kill $CTID || fail "unable to stop"
	else
		osctl ct stop $CTID || fail "unable to stop"
	fi
fi
osctl ct passwd $CTID root suCHS3crET || fail "unable to set password"
