function test_network {
	# We assume that the bridge is setup in OS configuration using
	#
	#   networking.lxcbr = true;
	#   networking.dhcpd = true;
	#
	local ip=$(osctl ct exec $CTID ip route get 192.168.1.1 | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')
	local rc=$?
	[ $rc != 0 ] && return $rc

	ping -c 1 $ip > /dev/null 2>&1
}

osctl ct netif new bridge --link lxcbr0 $CTID eth0 || fail "unable to add netif"
osctl ct start $CTID || fail "unable to start container"

for i in {1..60} ; do
	test_network && exit 0
	sleep 1
done

exit 1
