args@{ pkgs, ... }:

import ./network-backlog-unregister-serialization.nix (
  args
  // {
    profile = {
      fixId = "ipv6-multicast-unresolved-dst-lifetime";
      oracleId = "ipv6-multicast-routing-operation-safety";
      toolName = "ipv6-multicast-routing-operation";
      operationLabel = "IPv6 multicast-router control and traffic";
      kernelModules = [

      ];
      extraPackages = [ ];
      cleanupFixture = ''
        for ns in $(ip netns list | awk '$1 ~ /^lp-mroute6-[0-9]+$/ { print $1 }'); do
          ip netns del "$ns"
        done
      '';
      setupFixture = ''
        cleanup_fixture
      '';
      oneIteration = ''
              ns=lp-mroute6-$$
              ip netns add "$ns"
              ip -n "$ns" link set lo up
              ip -n "$ns" link add mrt0 type dummy
              ip -n "$ns" addr add 2001:db8:66::1/64 dev mrt0
              ip -n "$ns" link set mrt0 up
              if ! ip netns exec "$ns" python3 - <<'PY'
        import socket
        ctl = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6)
        ctl.setsockopt(socket.IPPROTO_IPV6, 200, 1)
        index = socket.if_nametoindex("mrt0")
        sender = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        sender.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, index)
        sender.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_LOOP, 1)
        sender.sendto(b"ordinary-ipv6-multicast", ("ff02::1", 24680, 0, index))
        sender.close()
        ctl.setsockopt(socket.IPPROTO_IPV6, 201, b"")
        ctl.close()
        PY
              then
                ip netns del "$ns"
                return 1
              fi
              ip netns del "$ns"
      '';
    };
  }
)
