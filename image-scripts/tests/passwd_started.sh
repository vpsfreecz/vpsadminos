osctl ct start $CTID || fail "unable to start container"

# On NixOS, we have to wait a bit for the start menu to pass, because
# we need the initial system activation to take place before the password
# can be set.
[ "$DISTNAME" == "nixos" ] && sleep 10

osctl ct passwd $CTID root suCHS3crET || fail "unable to set password"
