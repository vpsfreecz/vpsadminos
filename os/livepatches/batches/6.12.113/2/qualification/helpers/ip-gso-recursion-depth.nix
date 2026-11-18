args@{ pkgs, ... }:

import ./network-backlog-unregister-serialization.nix (
  args
  // {
    profile = {
      fixId = "ip-gso-recursion-depth";
      oracleId = "ip-gso-tunnel-operation-safety";
      toolName = "ip-gso-tunnel-operation";
      operationLabel = "shallow IP tunnel TCP GSO traffic";
      kernelModules = [
        "ipip"
      ];
      extraPackages = [ ];
      cleanupFixture = ''
        if test -f "$state_dir/server.pid"; then
          server_pid=$(cat "$state_dir/server.pid")
          kill "$server_pid" >/dev/null 2>&1 || true
          timeout 10 tail --pid="$server_pid" -f /dev/null || true
          rm -f "$state_dir/server.pid" "$state_dir/server.log" "$state_dir/server.ready"
        fi
        ip netns del lp-gso-a >/dev/null 2>&1 || true
        ip netns del lp-gso-b >/dev/null 2>&1 || true
      '';
      setupFixture = ''
              cleanup_fixture
              ip netns add lp-gso-a
              ip netns add lp-gso-b
              ip link add gsoa0 type veth peer name gsob0
              ip link set gsoa0 netns lp-gso-a
              ip link set gsob0 netns lp-gso-b
              ip -n lp-gso-a link set lo up
              ip -n lp-gso-b link set lo up
              ip -n lp-gso-a addr add 10.80.0.1/30 dev gsoa0
              ip -n lp-gso-b addr add 10.80.0.2/30 dev gsob0
              ip -n lp-gso-a link set gsoa0 up
              ip -n lp-gso-b link set gsob0 up
              ip -n lp-gso-a tunnel add gso0 mode ipip local 10.80.0.1 remote 10.80.0.2 ttl 64
              ip -n lp-gso-b tunnel add gso0 mode ipip local 10.80.0.2 remote 10.80.0.1 ttl 64
              ip -n lp-gso-a addr add 192.0.2.25/30 dev gso0
              ip -n lp-gso-b addr add 192.0.2.26/30 dev gso0
              ip -n lp-gso-a link set gso0 mtu 1400 up
              ip -n lp-gso-b link set gso0 mtu 1400 up
              ip netns exec lp-gso-b python3 -u - <<'PY' > "$state_dir/server.log" 2>&1 &
        import hashlib
        import socket
        import struct
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("192.0.2.26", 24800))
        server.listen(8)
        open("/run/ip-gso-recursion-depth-operation/server.ready", "w").close()

        def receive_exact(conn, length):
            data = bytearray()
            while len(data) < length:
                chunk = conn.recv(length - len(data))
                if not chunk:
                    raise RuntimeError("short TCP payload")
                data.extend(chunk)
            return bytes(data)

        while True:
            conn, _ = server.accept()
            length = struct.unpack("!I", receive_exact(conn, 4))[0]
            data = receive_exact(conn, length)
            conn.sendall(hashlib.sha256(data).digest())
            conn.close()
        PY
              printf '%s\n' "$!" > "$state_dir/server.pid"
              for _ in $(seq 1 100); do
                test ! -f "$state_dir/server.ready" || break
                sleep 0.05
              done
              test -f "$state_dir/server.ready" || fail "GSO TCP server did not become ready"
      '';
      oneIteration = ''
              ip netns exec lp-gso-a python3 - <<'PY'
        import hashlib
        import socket
        import struct
        payload = (b"ordinary-gso-tunnel-traffic-" * 10000)[:262144]
        client = socket.create_connection(("192.0.2.26", 24800), timeout=5)
        client.sendall(struct.pack("!I", len(payload)) + payload)
        digest = bytearray()
        while len(digest) < 32:
            digest.extend(client.recv(32 - len(digest)))
        assert bytes(digest) == hashlib.sha256(payload).digest()
        client.close()
        PY
      '';
    };
  }
)
