args@{ pkgs, ... }:

import ./network-backlog-unregister-serialization.nix (
  args
  // {
    profile = {
      fixId = "bridge-multicast-port-group-teardown";
      oracleId = "bridge-multicast-operation-safety";
      toolName = "bridge-multicast-operation";
      operationLabel = "bridge multicast membership and port lifecycle";
      kernelModules = [
        "bridge"
      ];
      extraPackages = [ ];
      cleanupFixture = ''
        ip netns del lp-bridge >/dev/null 2>&1 || true
      '';
      setupFixture = ''
        cleanup_fixture
        ip netns add lp-bridge
        ip -n lp-bridge link set lo up
        ip -n lp-bridge link add br0 type bridge mcast_snooping 1
        ip -n lp-bridge link add brp0 type veth peer name brp1
        ip -n lp-bridge link set brp0 master br0
        ip -n lp-bridge addr add 192.0.2.17/30 dev br0
        ip -n lp-bridge addr add 192.0.2.18/30 dev brp1
        ip -n lp-bridge link set br0 up
        ip -n lp-bridge link set brp0 up
        ip -n lp-bridge link set brp1 up
      '';
      oneIteration = ''
              ip netns exec lp-bridge python3 - <<'PY'
        import socket
        import struct
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("192.0.2.18", 0))
        membership = socket.inet_aton("239.255.0.1") + socket.inet_aton("192.0.2.18")
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)
        sock.sendto(b"ordinary-bridge-multicast", ("239.255.0.1", 24700))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_DROP_MEMBERSHIP, membership)
        sock.close()
        PY
              ip -n lp-bridge link set brp0 nomaster
              ip -n lp-bridge link set brp0 master br0
              ip netns exec lp-bridge ping -q -c 1 -W 2 192.0.2.17 >/dev/null
      '';
    };
  }
)
