osctl ct start $CTID || fail "unable to start container"
osctl ct passwd $CTID root secret || fail "unable to set password"
