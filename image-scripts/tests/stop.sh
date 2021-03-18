osctl ct start $CTID || fail "unable to start container"

# Give the system some time to complete boot
if [ "$DISTNAME" == "debian" ] && [ "$RELVER" == "8" ] ; then
	sleep 30
else
	sleep 10
fi

osctl ct stop --dont-kill $CTID || fail "unable to stop container"
