osctl ct start $CTID || fail "unable to start container"

# Give the system some time to complete boot
if [ "$DISTNAME" == "debian" ] && [ "$RELVER" == "8" ] ; then
	sleep 30
else
	sleep 10
fi

# TODO: find a way to fix this
# See https://github.com/vpsfreecz/vpsadminos/issues/39
if [ "$DISTNAME" == "void" ] ; then
	osctl ct stop $CTID || fail "unable to stop container"
else
	osctl ct stop --dont-kill $CTID || fail "unable to stop container"
fi
