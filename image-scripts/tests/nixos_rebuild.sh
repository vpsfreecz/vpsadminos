if [ "$DISTNAME" != "nixos" ] ; then
	echo "Not NixOS, ignoring"
	exit 0
fi

IPADDR="$OSCTL_IMAGE_TEST_IPV4_ADDRESS"

function test_network {
	ping -c 1 $IPADDR > /dev/null 2>&1
}

function wait_for_network {
	for i in {1..60} ; do
		test_network && return
		sleep 1
	done

	return 1
}

function has_flake {
	osctl ct exec $CTID test -f /etc/nixos/flake.nix
}

function wait_for_flake {
	for i in {1..60} ; do
		has_flake && return
		sleep 1
	done

	return 1
}

function test_dns {
	osctl ct exec $CTID getent hosts github.com > /dev/null 2>&1
}

function wait_for_dns {
	for i in {1..60} ; do
		test_dns && return
		sleep 1
	done

	return 1
}

osctl ct netif new routed $CTID eth0 || fail "unable to add netif"
osctl ct netif ip add $CTID eth0 $IPADDR/32 || fail "unable to add ip"
osctl ct start $CTID || fail "unable to start container"

wait_for_network || fail "network unreachable"
wait_for_flake || fail "flake configuration not created"
wait_for_dns || fail "DNS not working"

osctl ct exec $CTID nixos-rebuild switch --flake /etc/nixos#vps \
	|| fail "unable to run nixos-rebuild switch"
