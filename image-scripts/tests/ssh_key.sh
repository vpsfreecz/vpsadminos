IPADDR="$OSCTL_IMAGE_TEST_IPV4_ADDRESS"
PRIVATE_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQQLZ1lnTtm8gtZwEVZv/vdALqVOTPFh
NxfhZ/Oc6FtN9DNprhyhLfjeJruj+CgM3WG7MUsafrofHkNobNK6bwhCAAAAqG6w9rNusP
azAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBAtnWWdO2byC1nAR
Vm/+90AupU5M8WE3F+Fn85zoW030M2muHKEt+N4mu6P4KAzdYbsxSxp+uh8eQ2hs0rpvCE
IAAAAhALZTz6hRZCvnFXdUEhV9wICapfciz/MGy7Ohx3uRPYuiAAAADGFpdGhlckBvcmlv
bgECAw==
-----END OPENSSH PRIVATE KEY-----"
PUBLIC_KEY="ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBAtnWWdO2byC1nARVm/+90AupU5M8WE3F+Fn85zoW030M2muHKEt+N4mu6P4KAzdYbsxSxp+uh8eQ2hs0rpvCEI= template@test"

function test_network {
	ping -c 1 $IPADDR > /dev/null 2>&1
}

function install_script {
	cat <<EOF
#!/bin/sh
mkdir -p /root/.ssh
echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys
EOF
}

function install_key {
	osctl ct runscript $CTID <(install_script)
}

function reject_nokey {
	ssh -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o BatchMode=yes \
		root@$IPADDR hostname
	[ $? != 0 ]
}

function accept_key {
	local identity=$(mktemp)
	local rc=

	echo "$PRIVATE_KEY" > "$identity"
	ssh -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o BatchMode=yes \
		-i "$identity" \
		root@$IPADDR hostname
	rc=$?
	rm -f "$identity"
	return $rc
}

function test_ssh {
	install_key || fail "failed to install public key"
	reject_nokey || fail "accepted invalid key"
	accept_key || fail "rejected valid key"
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
