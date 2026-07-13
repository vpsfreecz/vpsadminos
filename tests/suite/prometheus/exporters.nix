import ../../make-test.nix (
  { pkgs }:
  let
    bpfLivepatchProgram = "override_uname";
    bpfLivepatchPins = [
      "override_uname__uname_fentry"
      "override_uname__uname_fexit"
    ];

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

    testScriptJobs = 5;

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = {
        environment.etc."vpsadminos/livepatch-monitor.json".text = builtins.toJSON {
          module = "missing_livepatch_test";
          patchVersion = 999;
        };

        services.ebpf-livepatch = {
          enable = true;
          # Select a non-expiring program explicitly. The default set can be
          # empty after a mitigation ages out for the current kernel.
          programs.${bpfLivepatchProgram} = { };
        };
        services.live-patches.enable = false;

        services.prometheus.exporters.ebpf = {
          enable = true;
          names = [ "rtnl_lock-latency" ];
        };
        services.prometheus.exporters.osctl.enable = true;
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

      kernel_protection = {
        description = ''
          Test vpsAdminOS kernel protection metrics from osctl-exporter
        '';
        script = helpers + ''
          BPF_LIVEPATCH_PROGRAM = ${builtins.toJSON bpfLivepatchProgram}
          BPF_LIVEPATCH_PINS = ${builtins.toJSON bpfLivepatchPins}

          before(:suite) do
            machine.start unless machine.running?
            machine.wait_until_online
            machine.wait_for_osctl_pool('tank')
            machine.wait_for_service('ebpf-livepatch')
            machine.wait_for_service('prometheus-osctl-exporter')
          end

          describe 'vpsAdminOS kernel protection metrics' do
            it 'exports required and loaded BPF livepatch programs' do
              wait_until_block_succeeds(name: 'BPF livepatch metrics') do
                metrics = fetch_metrics(9101)
                required = find_metric_line(
                  metrics,
                  'kernel_bpf_program_required',
                  program: BPF_LIVEPATCH_PROGRAM
                )
                loaded = find_metric_line(
                  metrics,
                  'kernel_bpf_program_loaded',
                  program: BPF_LIVEPATCH_PROGRAM
                )
                success = find_metric_line(
                  metrics,
                  'kernel_protection_monitoring_success',
                  component: 'bpf'
                )

                expect(required).not_to be_nil
                expect(required.split.last.to_f).to eq(1.0)
                expect(loaded).not_to be_nil
                expect(loaded.split.last.to_f).to eq(1.0)
                expect(success).not_to be_nil
                expect(success.split.last.to_f).to eq(1.0)
              end
            end

            it 'keeps BPF livepatch programs pinned across service reload' do
              pin = '/sys/fs/bpf/vpsadminos/ebpf-livepatch/generations'
              count_pins = BPF_LIVEPATCH_PINS.map do |pin_name|
                "test \"$(find #{pin} -name '#{pin_name}' -printf .)\" = ."
              end.join('; ')

              machine.succeeds(count_pins)
              machine.succeeds(
                'generation=$(cat /run/ebpf-livepatch/current-generation); ' \
                'test -s /run/ebpf-livepatch/$generation.attached-at; ' \
                'date -d "$(cat /run/ebpf-livepatch/$generation.attached-at)" >/dev/null'
              )
              machine.succeeds('sv 1 ebpf-livepatch')

              wait_until_block_succeeds(name: 'BPF livepatch reload') do
                machine.succeeds(count_pins)

                metrics = fetch_metrics(9101)
                loaded = find_metric_line(
                  metrics,
                  'kernel_bpf_program_loaded',
                  program: BPF_LIVEPATCH_PROGRAM
                )

                expect(loaded).not_to be_nil
                expect(loaded.split.last.to_f).to eq(1.0)
              end
            end

            it 'exports required but unloaded kernel livepatches' do
              wait_until_block_succeeds(name: 'kernel livepatch metrics') do
                metrics = fetch_metrics(9101)
                required = find_metric_line(
                  metrics,
                  'kernel_livepatch_required',
                  module: 'missing_livepatch_test',
                  patch_version: '999'
                )
                loaded = find_metric_line(
                  metrics,
                  'kernel_livepatch_loaded',
                  module: 'missing_livepatch_test',
                  patch_version: '999'
                )
                success = find_metric_line(
                  metrics,
                  'kernel_protection_monitoring_success',
                  component: 'livepatch'
                )

                expect(required).not_to be_nil
                expect(required.split.last.to_f).to eq(1.0)
                expect(loaded).not_to be_nil
                expect(loaded.split.last.to_f).to eq(0.0)
                expect(success).not_to be_nil
                expect(success.split.last.to_f).to eq(1.0)
              end
            end
          end
        '';
      };
    };
  }
)
