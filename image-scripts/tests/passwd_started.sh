osctl ct start $CTID || fail "unable to start container"
osctl ct passwd $CTID root suCHS3crET || fail "unable to set password"
