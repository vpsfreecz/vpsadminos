args@{ pkgs, ... }:

import ./network-backlog-unregister-serialization.nix (
  args
  // {
    profile = {
      fixId = "sctp-address-work-teardown";
      oracleId = "sctp-address-work-operation-safety";
      toolName = "sctp-address-work-operation";
      operationLabel = "SCTP namespace and socket lifecycle";
      kernelModules = [
        "sctp"
      ];
      extraPackages = [ ];
      cleanupFixture = ''
        for ns in $(ip netns list | awk '$1 ~ /^lp-sctp-[0-9]+$/ { print $1 }'); do
          ip netns del "$ns"
        done
      '';
      setupFixture = ''
        cleanup_fixture
      '';
      oneIteration = ''
              ns=lp-sctp-$$
              ip netns add "$ns"
              ip -n "$ns" link set lo up
              if ! ip netns exec "$ns" python3 - <<'PY'
        import socket
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_SCTP)
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        client = socket.socket(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_SCTP)
        client.connect(server.getsockname())
        accepted, _ = server.accept()
        client.sendall(b"ordinary-sctp-operation")
        assert accepted.recv(64) == b"ordinary-sctp-operation"
        accepted.sendall(b"ok")
        assert client.recv(2) == b"ok"
        accepted.close()
        client.close()
        server.close()
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
