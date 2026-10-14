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

if [ "$VARIANT" == "impermanence" ] ; then
	machine_id=$(osctl ct exec $CTID cat /etc/machine-id) \
		|| fail "unable to read initial machine-id"
	[ -n "$machine_id" ] || fail "empty initial machine-id"

	# Add an allocated system identity and persistent payload to the generated
	# configuration, leaving its original persistence settings and imports intact.
	osctl ct exec $CTID bash -c 'cat > /etc/nixos/preservation-test.nix <<"EOF"
{ ... }:
{
  users.groups.preservation-test = {};
  users.users.preservation-test = {
    isSystemUser = true;
    group = "preservation-test";
  };
  environment.persistence."/persistent".directories = [
    "/var/lib/preservation-test"
  ];
}
EOF
sed -i "/^{$/a\  imports = [ ./preservation-test.nix ];" /etc/nixos/configuration.nix' \
		|| fail "unable to configure impermanence preservation fixture"
fi

osctl ct exec $CTID nixos-rebuild switch --flake /etc/nixos#vps \
	|| fail "unable to run nixos-rebuild switch"

if [ "$VARIANT" == "impermanence" ] ; then
	osctl ct exec $CTID bash -c '
printf "%s\n" "vpsadminos-impermanence-preservation" > /var/lib/preservation-test/payload
chown preservation-test:preservation-test /var/lib/preservation-test/payload
' || fail "unable to create impermanence payload"

	identity=$(osctl ct exec $CTID id -u preservation-test) \
		|| fail "unable to read fixture UID"
	group_identity=$(osctl ct exec $CTID id -g preservation-test) \
		|| fail "unable to read fixture GID"

	function test_preservation {
		local phase="$1" failed=0
		local current_machine_id current_identity current_group_identity
		local current_payload current_ownership

		# Collect every invariant before reporting failure, so one changed ID
		# cannot hide the state of the other identity or the persistent payload.
		current_machine_id=$(osctl ct exec $CTID cat /etc/machine-id) || failed=1
		current_identity=$(osctl ct exec $CTID id -u preservation-test) || failed=1
		current_group_identity=$(osctl ct exec $CTID id -g preservation-test) || failed=1
		current_payload=$(osctl ct exec $CTID cat /var/lib/preservation-test/payload) || failed=1
		current_ownership=$(osctl ct exec $CTID stat -c %u:%g /var/lib/preservation-test/payload) || failed=1

		printf 'Preservation after %s:\n' "$phase"
		printf '  machine-id: expected <%s>, current <%s>\n' "$machine_id" "$current_machine_id"
		printf '  UID: expected <%s>, current <%s>\n' "$identity" "$current_identity"
		printf '  GID: expected <%s>, current <%s>\n' "$group_identity" "$current_group_identity"
		printf '  payload: expected <%s>, current <%s>\n' "vpsadminos-impermanence-preservation" "$current_payload"
		printf '  ownership: expected <%s>, current <%s>\n' "$identity:$group_identity" "$current_ownership"

		# Read-only evidence from both the visible mount and its backing storage.
		osctl ct exec $CTID bash -c '
for path in /var/lib/nixos/uid-map /var/lib/nixos/gid-map /persistent/var/lib/nixos/uid-map /persistent/var/lib/nixos/gid-map; do
  printf "\nAllocation map %s:\n" "$path"
  if [ -f "$path" ]; then cat "$path"; else printf "missing\n"; fi
done
for path in /var/lib/nixos /persistent/var/lib/nixos /var/lib/preservation-test /persistent/var/lib/preservation-test; do
  printf "\nMount and backing identity %s:\n" "$path"
  findmnt --target "$path" --output TARGET,SOURCE,FSTYPE,OPTIONS
  stat -c "%n owner=%u:%g mode=%a device:inode=%d:%i" "$path"
done
printf "\nPersistent payload backing state:\n"
stat -c "%n owner=%u:%g mode=%a device:inode=%d:%i" /var/lib/preservation-test/payload /persistent/var/lib/preservation-test/payload
printf "\nBoot mount and activation order:\n"
grep -n -E "proc/1|source .*mounts|running activation|systemConfig/activate" /run/current-system/init
mount_script=$(sed -n "s/^[[:space:]]*source \([^[:space:]]*-mounts\.sh\).*$/\1/p" /run/current-system/init)
if [ -n "$mount_script" ] && [ -f "$mount_script" ]; then
  grep -n -E "persistent|var/lib/nixos|specialMount" "$mount_script"
fi
printf "\nUser and persistence activation steps:\n"
grep -n -E "specialfs|Activation script snippet|source[[:space:]]+.*-mounts[.]sh|update-users-groups|uid-map|gid-map|persistent|(^|[[:space:]])mount([[:space:]]|$)" /run/current-system/activate
' || printf 'Unable to collect all read-only preservation diagnostics after %s\n' "$phase"

		[ "$current_machine_id" == "$machine_id" ] || { echo "machine-id changed after $phase"; failed=1; }
		[ "$current_identity" == "$identity" ] || { echo "fixture UID changed after $phase"; failed=1; }
		[ "$current_group_identity" == "$group_identity" ] || { echo "fixture GID changed after $phase"; failed=1; }
		[ "$current_payload" == "vpsadminos-impermanence-preservation" ] || { echo "persistent payload changed after $phase"; failed=1; }
		[ "$current_ownership" == "$identity:$group_identity" ] || { echo "persistent payload ownership changed after $phase"; failed=1; }
		[ "$failed" -eq 0 ] || fail "impermanence preservation failed after $phase"
	}
	test_preservation initial-rebuild

	# An earlier-sorting identity changes fresh allocation order. Without the
	# persisted UID/GID maps, a restart could otherwise allocate the same IDs
	# accidentally and hide a regression.
	osctl ct exec $CTID bash -c 'sed -i "/^}$/i\  users.groups.a-preservation-test = {};\n  users.users.a-preservation-test = { isSystemUser = true; group = \"a-preservation-test\"; };" /etc/nixos/preservation-test.nix' \
		|| fail "unable to extend allocated identity fixture"
	osctl ct exec $CTID nixos-rebuild switch --flake /etc/nixos#vps \
		|| fail "unable to rebuild impermanence fixture"
	test_preservation rebuild
fi

osctl ct restart $CTID || fail "unable to restart rebuilt container"
wait_for_network || fail "network unreachable after restart"
wait_for_flake || fail "flake configuration missing after restart"
wait_for_dns || fail "DNS not working after restart"

if [ "$VARIANT" == "impermanence" ] ; then
	test_preservation restart
fi
