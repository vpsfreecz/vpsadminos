import ../../make-test.nix (
  { pkgs }:
  let
    helpers = ''
      def fetch_metrics(port)
        machine.succeeds("curl -sSf http://127.0.0.1:#{port}/metrics")[1]
      end

      def find_metric_line(metrics, metric_name, labels = {})
        metrics.lines.find do |line|
          next false unless line.start_with?("#{metric_name}{") || line.start_with?("#{metric_name} ")

          labels.all? do |key, value|
            line.include?(%Q(#{key}="#{value}"))
          end
        end
      end
    '';
  in
  {
    name = "prometheus-exporters";

    description = ''
      Test Prometheus exporters
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = {
        services.prometheus.exporters.ebpf = {
          enable = true;
          names = [ "rtnl_lock-latency" ];
        };
        services.prometheus.exporters.zfs.enable = true;
      };
    };

    testScripts = {
      ebpf = {
        description = ''
          Test Prometheus eBPF exporter with rtnl_lock latency example
        '';
        script = helpers + ''
          before(:suite) do
            machine.start unless machine.running?
            machine.wait_until_online
            machine.wait_for_osctl_pool('tank')
            machine.wait_for_service('prometheus-ebpf-exporter')
          end

          describe 'Prometheus eBPF exporter' do
            it 'exports the configured example' do
              wait_until_block_succeeds(name: 'ebpf exporter configured metric') do
                metrics = fetch_metrics(9435)
                line = find_metric_line(
                  metrics,
                  'ebpf_exporter_enabled_configs',
                  name: 'rtnl_lock-latency'
                )

                expect(line).not_to be_nil
                expect(line.strip).to eq(
                  'ebpf_exporter_enabled_configs{name="rtnl_lock-latency"} 1'
                )
              end
            end

            it 'reports latency samples after route churn' do
              machine.succeeds(
                'for i in $(seq 1 64); do ' \
                'ip route add blackhole 198.19.$((i % 255)).0/24 >/dev/null 2>&1 || true; ' \
                'ip route del blackhole 198.19.$((i % 255)).0/24 >/dev/null 2>&1 || true; ' \
                'done'
              )

              wait_until_block_succeeds(name: 'ebpf exporter latency counter') do
                metrics = fetch_metrics(9435)
                line = find_metric_line(
                  metrics,
                  'ebpf_exporter_rtnl_lock_latency_seconds_count'
                )

                expect(line).not_to be_nil
                expect(line.split.last.to_f).to be > 0
              end
            end
          end
        '';
      };

      zfs = {
        description = ''
          Test Prometheus ZFS exporter on the tank pool
        '';
        script = helpers + ''
          before(:suite) do
            machine.start unless machine.running?
            machine.wait_until_online
            machine.wait_for_osctl_pool('tank')
            machine.wait_for_service('prometheus-zfs-exporter')
          end

          describe 'Prometheus ZFS exporter' do
            it 'exports pool metrics for configured pools' do
              wait_until_block_succeeds(name: 'zfs exporter pool metric') do
                metrics = fetch_metrics(9134)
                line = find_metric_line(
                  metrics,
                  'zfs_pool_size_bytes',
                  pool: 'tank'
                )

                expect(line).not_to be_nil
              end
            end

            it 'exports the default filesystem compression metrics' do
              wait_until_block_succeeds(
                name: 'zfs exporter filesystem compression metrics'
              ) do
                metrics = fetch_metrics(9134)
                compression = find_metric_line(
                  metrics,
                  'zfs_dataset_compression_ratio',
                  name: 'tank',
                  pool: 'tank',
                  type: 'filesystem'
                )
                refcompression = find_metric_line(
                  metrics,
                  'zfs_dataset_referenced_compression_ratio',
                  name: 'tank',
                  pool: 'tank',
                  type: 'filesystem'
                )

                expect(compression).not_to be_nil
                expect(refcompression).not_to be_nil
              end
            end
          end
        '';
      };
    };
  }
)
