function can_set {
	osctl ct set dns-resolver "$CTID" "$@"
}

function can_unset {
	osctl ct unset dns-resolver "$CTID"
}

function has_nameserver {
	local ns="$1"
	if ! osctl ct exec "$CTID" cat /etc/resolv.conf | grep -qx "nameserver $ns" ; then
		echo "nameserver '$ns' not found in /etc/resolv.conf"
		return 1
	fi
}

function has_not_nameserver {
	local ns="$1"
	if osctl ct exec "$CTID" cat /etc/resolv.conf | grep -qx "nameserver $ns" ; then
		echo "nameserver '$ns' found in /etc/resolv.conf"
		return 1
	fi
}

function has_exact_nameservers {
	local expected="$1"
	local actual
	actual=$(osctl ct exec "$CTID" cat /etc/resolv.conf | grep '^nameserver ' || true)

	if [ "$actual" != "$expected" ] ; then
		echo "unexpected nameservers in /etc/resolv.conf"
		echo "expected:"
		echo "$expected"
		echo "actual:"
		echo "$actual"
		return 1
	fi
}

function has_any_nameserver {
	osctl ct exec "$CTID" cat /etc/resolv.conf | grep -q '^nameserver '
}

function wait_for_nameserver {
	local ns="$1"
	local attempt

	for attempt in {1..30} ; do
		if has_nameserver "$ns" > /dev/null 2>&1 ; then
			return 0
		fi

		sleep 1
	done

	has_nameserver "$ns"
}

function wait_for_any_nameserver {
	local attempt

	for attempt in {1..30} ; do
		if has_any_nameserver > /dev/null 2>&1 ; then
			return 0
		fi

		sleep 1
	done

	has_any_nameserver
}

managed_first="192.0.2.53"
managed_second="198.51.100.53"
managed_ipv6="2001:db8::53"

osctl ct stop "$CTID"

if [ "$DISTNAME" == "nixos" ] ; then
	test_ip="$OSCTL_IMAGE_TEST_IPV4_ADDRESS"
	osctl ct netif new routed "$CTID" eth0 \
		|| fail "unable to add routed netif for nixos-rebuild"
	osctl ct netif ip add "$CTID" eth0 "$test_ip/32" \
		|| fail "unable to add routed address for nixos-rebuild"
fi

can_set "$managed_first" || fail "unable to set dns resolvers when stopped"
osctl ct start "$CTID"
wait_for_nameserver "$managed_first" || fail "dns resolver isn't set after start"
has_exact_nameservers "nameserver $managed_first" \
	|| fail "unexpected resolver set after start"
sleep 30 # make sure that nothing from inside the vps will override it
has_nameserver "$managed_first" || fail "dns resolver lost after start"

if [ "$DISTNAME" == "nixos" ] ; then
	rebuild_resolver=$(awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf)
	[ -n "$rebuild_resolver" ] || fail "test host has no DNS resolver"
	can_set "$rebuild_resolver" \
		|| fail "unable to set routed resolver for nixos-rebuild"
	has_exact_nameservers "nameserver $rebuild_resolver" \
		|| fail "routed resolver isn't set for nixos-rebuild"
	osctl ct exec "$CTID" nixos-rebuild switch --flake /etc/nixos#vps \
		|| fail "unable to rebuild NixOS with managed resolvers"
	has_exact_nameservers "nameserver $rebuild_resolver" \
		|| fail "managed resolvers lost after nixos-rebuild"
fi

can_set "$managed_second" || fail "unable to set dns resolver when started"
has_nameserver "$managed_second" || fail "dns resolver isn't set at runtime"
has_not_nameserver "$managed_first" || fail "replaced dns resolver wasn't removed"
if [ "$DISTNAME" == "nixos" ] && [ "$rebuild_resolver" != "$managed_second" ] ; then
	has_not_nameserver "$rebuild_resolver" \
		|| fail "rebuild resolver wasn't removed"
fi

osctl ct restart "$CTID" || fail "unable to restart"
wait_for_nameserver "$managed_second" || fail "dns resolvers aren't persisted"

can_set "$managed_first" "$managed_ipv6" "$managed_second" \
	|| fail "unable to set multiple dns resolvers"
has_nameserver "$managed_first" || fail "first IPv4 dns resolver not found"
has_nameserver "$managed_ipv6" || fail "IPv6 dns resolver not found"
has_nameserver "$managed_second" || fail "second IPv4 dns resolver not found"
has_exact_nameservers "$(printf 'nameserver %s\n' \
	"$managed_first" "$managed_ipv6" "$managed_second")" \
	|| fail "multiple dns resolvers are not exact or ordered"

if [ "$DISTNAME" == "nixos" ] ; then
	can_unset || fail "unable to clear managed dns resolvers"
	has_not_nameserver "$managed_first" || fail "managed resolver remains after clear"
	has_not_nameserver "$managed_ipv6" \
		|| fail "managed IPv6 resolver remains after clear"
	has_not_nameserver "$managed_second" || fail "managed resolver remains after clear"
	has_any_nameserver || fail "NixOS fallback resolvers missing after clear"

	osctl ct restart "$CTID" || fail "unable to restart after resolver clear"
	wait_for_any_nameserver \
		|| fail "NixOS fallback resolvers missing after restart"
	has_not_nameserver "$managed_first" || fail "managed resolver returned after restart"
	has_not_nameserver "$managed_ipv6" \
		|| fail "managed IPv6 resolver returned after restart"
	has_not_nameserver "$managed_second" || fail "managed resolver returned after restart"
fi
