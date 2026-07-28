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

function can_resolve {
	osctl ct exec "$CTID" getent hosts github.com > /dev/null 2>&1
}

osctl ct stop "$CTID"
can_set "1.1.1.1" || fail "unable to set dns resolvers when stopped"
osctl ct start "$CTID"
has_nameserver "1.1.1.1" || fail "dns resolver isn't set after start"
has_exact_nameservers "nameserver 1.1.1.1" \
	|| fail "unexpected resolver set after start"
sleep 30 # make sure that nothing from inside the vps will override it
has_nameserver "1.1.1.1" || fail "dns resolver lost after start"
can_resolve || fail "DNS lookup failed with managed resolvers"

can_set "8.8.8.8" || fail "unable to set dns resolver when started"
has_nameserver "8.8.8.8" || fail "dns resolver isn't set at runtime"
has_not_nameserver "1.1.1.1" || fail "replaced dns resolver wasn't removed"

if [ "$DISTNAME" == "nixos" ] ; then
	osctl ct exec "$CTID" nixos-rebuild switch --flake /etc/nixos#vps \
		|| fail "unable to rebuild NixOS with managed resolvers"
	has_exact_nameservers "nameserver 8.8.8.8" \
		|| fail "managed resolvers lost after nixos-rebuild"
fi

osctl ct restart "$CTID" || fail "unable to restart"
has_nameserver "8.8.8.8" || fail "dns resolvers aren't persisted"

can_set 1.1.1.1 2606:4700:4700::1111 8.8.8.8 \
	|| fail "unable to set multiple dns resolvers"
has_nameserver "1.1.1.1" || fail "dns resolver 1.1.1.1 not found"
has_nameserver "2606:4700:4700::1111" || fail "IPv6 dns resolver not found"
has_nameserver "8.8.8.8" || fail "dns resolver 8.8.8.8 not found"
has_exact_nameservers "$(printf '%s\n' \
	'nameserver 1.1.1.1' \
	'nameserver 2606:4700:4700::1111' \
	'nameserver 8.8.8.8')" \
	|| fail "multiple dns resolvers are not exact or ordered"

if [ "$DISTNAME" == "nixos" ] ; then
	can_unset || fail "unable to clear managed dns resolvers"
	has_not_nameserver "1.1.1.1" || fail "managed resolver remains after clear"
	has_not_nameserver "2606:4700:4700::1111" \
		|| fail "managed IPv6 resolver remains after clear"
	has_not_nameserver "8.8.8.8" || fail "managed resolver remains after clear"
	has_any_nameserver || fail "NixOS fallback resolvers missing after clear"

	osctl ct restart "$CTID" || fail "unable to restart after resolver clear"
	has_not_nameserver "1.1.1.1" || fail "managed resolver returned after restart"
	has_not_nameserver "2606:4700:4700::1111" \
		|| fail "managed IPv6 resolver returned after restart"
	has_not_nameserver "8.8.8.8" || fail "managed resolver returned after restart"
	has_any_nameserver || fail "NixOS fallback resolvers missing after restart"
fi
