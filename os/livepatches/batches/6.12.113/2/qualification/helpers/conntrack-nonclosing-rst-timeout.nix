args@{ pkgs, ... }:

import ./network-backlog-unregister-serialization.nix (
  args
  // {
    profile = {
      fixId = "conntrack-nonclosing-rst-timeout";
      oracleId = "conntrack-tcp-operation-safety";
      toolName = "conntrack-tcp-operation";
      operationLabel = "ordinary tracked TCP connection lifecycle";
      kernelModules = [
        "nf_conntrack"
        "nf_tables"
      ];
      extraPackages = [ ];
      cleanupFixture = ''
        if test -f "$state_dir/server.pid"; then
          server_pid=$(cat "$state_dir/server.pid")
          kill "$server_pid" >/dev/null 2>&1 || true
          timeout 10 tail --pid="$server_pid" -f /dev/null || true
          rm -f "$state_dir/server.pid" "$state_dir/server.log" "$state_dir/server.ready"
        fi
        ip netns del lp-ct-a >/dev/null 2>&1 || true
        ip netns del lp-ct-b >/dev/null 2>&1 || true
      '';
      setupFixture = ''
              cleanup_fixture
              ip netns add lp-ct-a
              ip netns add lp-ct-b
              ip link add cta0 type veth peer name ctb0
              ip link set cta0 netns lp-ct-a
              ip link set ctb0 netns lp-ct-b
              ip -n lp-ct-a link set lo up
              ip -n lp-ct-b link set lo up
              ip -n lp-ct-a addr add 10.81.0.1/30 dev cta0
              ip -n lp-ct-b addr add 10.81.0.2/30 dev ctb0
              ip -n lp-ct-a link set cta0 up
              ip -n lp-ct-b link set ctb0 up
              ip netns exec lp-ct-b nft -f - <<'NFT'
        table inet lpct {
          chain input {
            type filter hook input priority 0; policy accept;
            ct state new,established counter accept
          }
        }
        NFT
              ip netns exec lp-ct-b python3 -u - <<'PY' > "$state_dir/server.log" 2>&1 &
        import socket
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("10.81.0.2", 24900))
        server.listen(8)
        open("/run/conntrack-nonclosing-rst-timeout-operation/server.ready", "w").close()
        while True:
            conn, _ = server.accept()
            data = conn.recv(128)
            conn.sendall(data)
            conn.shutdown(socket.SHUT_WR)
            conn.close()
        PY
              printf '%s\n' "$!" > "$state_dir/server.pid"
              for _ in $(seq 1 100); do
                test ! -f "$state_dir/server.ready" || break
                sleep 0.05
              done
              test -f "$state_dir/server.ready" || fail "conntrack TCP server did not become ready"
      '';
      oneIteration = ''
              ip netns exec lp-ct-a python3 - <<'PY'
        import socket
        payload = b"ordinary-conntrack-tcp-lifecycle"
        client = socket.create_connection(("10.81.0.2", 24900), timeout=5)
        client.sendall(payload)
        assert client.recv(128) == payload
        client.close()
        PY
              ip netns exec lp-ct-b nft list chain inet lpct input | grep -F 'ct state' >/dev/null
      '';
    };
  }
)
