IPADDR="10.100.10.1"
PASSWORD=suCHS3crET

function test_network {
	ping -c 1 $IPADDR > /dev/null 2>&1
}

function try_password {
	local pass="$1"
	sshpass \
		-p "$pass" \
		ssh -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o PubkeyAuthentication=no \
		root@$IPADDR hostname
}

function test_ssh {
	try_password notreally && fail "accepted unset password"
	try_password "" && fail "accepted empty password"
	osctl ct passwd $CTID root $PASSWORD || fail "unable to set password"
	try_password justno && fail "accepted invalid password"
	try_password $PASSWORD || fail "rejected valid password"
}

function wait_for_ssh {
	for k in {1..30} ; do
		nc -z $IPADDR 22 && return
		sleep 1
	done

	return 1
}

function wait_for_network {
	for i in {1..60} ; do
		test_network && return
		sleep 1
	done

	return 1
}

osctl ct netif new routed $CTID eth0 || fail "unable to add netif"
osctl ct netif ip add $CTID eth0 $IPADDR/32 || fail "unable to add ip"
osctl ct start $CTID || fail "unable to start"

wait_for_network || fail "network unreachable"
wait_for_ssh || fail "ssh not responding"
test_ssh
