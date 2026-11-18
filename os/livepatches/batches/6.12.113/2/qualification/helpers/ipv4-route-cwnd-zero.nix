args@{ pkgs, ... }:

import ./network-backlog-unregister-serialization.nix (
  args
  // {
    profile = {
      fixId = "ipv4-route-cwnd-zero";
      oracleId = "ipv4-route-metrics-operation-safety";
      toolName = "ipv4-route-metrics-operation";
      operationLabel = "valid locked nonzero route cwnd traffic";
      kernelModules = [

      ];
      extraPackages = [ ];
      cleanupFixture = ''
        if test -f "$state_dir/server.pid"; then
          server_pid=$(cat "$state_dir/server.pid")
          kill "$server_pid" >/dev/null 2>&1 || true
          timeout 10 tail --pid="$server_pid" -f /dev/null || true
          rm -f "$state_dir/server.pid" "$state_dir/server.log" "$state_dir/server.ready"
        fi
        ip netns del lp-cwnd-a >/dev/null 2>&1 || true
        ip netns del lp-cwnd-b >/dev/null 2>&1 || true
      '';
      setupFixture = ''
              cleanup_fixture
              ip netns add lp-cwnd-a
              ip netns add lp-cwnd-b
              ip link add cwa0 type veth peer name cwb0
              ip link set cwa0 netns lp-cwnd-a
              ip link set cwb0 netns lp-cwnd-b
              ip -n lp-cwnd-a link set lo up
              ip -n lp-cwnd-b link set lo up
              ip -n lp-cwnd-a addr add 10.82.0.1/30 dev cwa0
              ip -n lp-cwnd-b addr add 10.82.0.2/30 dev cwb0
              ip -n lp-cwnd-a link set cwa0 up
              ip -n lp-cwnd-b link set cwb0 up
              ip -n lp-cwnd-a route replace 10.82.0.0/30 dev cwa0 src 10.82.0.1 cwnd lock 10
              ip netns exec lp-cwnd-b python3 -u - <<'PY' > "$state_dir/server.log" 2>&1 &
        import socket
        import struct
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("10.82.0.2", 25000))
        server.listen(8)
        open("/run/ipv4-route-cwnd-zero-operation/server.ready", "w").close()

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
            conn.sendall(data)
            conn.close()
        PY
              printf '%s\n' "$!" > "$state_dir/server.pid"
              for _ in $(seq 1 100); do
                test ! -f "$state_dir/server.ready" || break
                sleep 0.05
              done
              test -f "$state_dir/server.ready" || fail "route-metric TCP server did not become ready"
      '';
      oneIteration = ''
              ip netns exec lp-cwnd-a python3 - <<'PY'
        import socket
        import struct
        payload = b"ordinary-valid-locked-cwnd" * 128
        client = socket.create_connection(("10.82.0.2", 25000), timeout=5)
        client.sendall(struct.pack("!I", len(payload)) + payload)
        received = bytearray()
        while len(received) < len(payload):
            received.extend(client.recv(len(payload) - len(received)))
        assert bytes(received) == payload
        client.close()
        PY
              ip -n lp-cwnd-a route show 10.82.0.0/30 | grep -F 'cwnd lock 10' >/dev/null
      '';
    };
  }
)
