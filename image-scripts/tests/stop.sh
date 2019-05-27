osctl ct start $CTID || fail "unable to start container"
osctl ct stop --dont-kill $CTID || fail "unable to stop container"
