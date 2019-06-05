osctl ct start $CTID || fail "unable to start container"
sleep 10 # give the system some time to complete boot
osctl ct stop --dont-kill $CTID || fail "unable to stop container"
