IPADDR="$OSCTL_IMAGE_TEST_IPV4_ADDRESS"
function test_network {
	ping -c 1 $IPADDR > /dev/null 2>&1
}

osctl ct netif new routed $CTID eth0 || fail "unable to add netif"
osctl ct netif ip add $CTID eth0 $IPADDR/32 || fail "unable to add ip"
osctl ct start $CTID || fail "unable to start"

for i in {1..60} ; do
	test_network && exit 0
	sleep 1
done

exit 1
