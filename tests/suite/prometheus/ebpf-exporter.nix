import ../../make-test.nix (
  { pkgs }:
  {
    name = "prometheus-ebpf-exporter";

    description = ''
      Test Prometheus eBPF exporter with rtnl_lock latency example
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config = {
        services.prometheus.exporters.ebpf = {
          enable = true;
          names = [ "rtnl_lock-latency" ];
        };
      };
    };

    testScript = ''
      machine.start
      machine.wait_until_online
      machine.wait_for_service("prometheus-ebpf-exporter")

      machine.wait_until_succeeds(
        "curl -sSf http://127.0.0.1:9435/metrics | grep 'ebpf_exporter_enabled_configs{name=\"rtnl_lock-latency\"} 1'"
      )

      machine.succeeds(
        "for i in $(seq 1 64); do ip route add blackhole 198.19.$((i % 255)).0/24 >/dev/null 2>&1 || true; ip route del blackhole 198.19.$((i % 255)).0/24 >/dev/null 2>&1 || true; done"
      )

      machine.wait_until_succeeds(
        "curl -sSf http://127.0.0.1:9435/metrics | awk '/^ebpf_exporter_rtnl_lock_latency_seconds_count / { if ($2+0 > 0) ok=1 } END { exit(ok ? 0 : 1) }'"
      )
    '';
  }
)
