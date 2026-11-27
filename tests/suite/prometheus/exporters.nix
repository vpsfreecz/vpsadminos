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

      def expect_metric_value(metrics, metric_name, value, labels = {})
        line = find_metric_line(metrics, metric_name, labels)

        expect(line).not_to be_nil
        expect(line.split.last.to_f).to eq(value)
      end

      def livepatch_monitor_entries
        path = '/etc/vpsadminos/livepatch-monitor.json'
        status, output = machine.execute("test ! -f #{path} || cat #{path}")
        expect(status).to eq(0)
        return [] if output.strip.empty?

        config = JSON.parse(output)
        entries = config.key?('modules') ? config.fetch('modules') : [config]
        entries.map do |entry|
          {
            module: entry.fetch('module'),
            patch_version: entry.fetch('patchVersion').to_s
          }
        end
      end

      def expect_livepatch_stack(metrics, entries)
        entries.each do |labels|
          expect_metric_value(metrics, 'kernel_livepatch_required', 1.0, labels)
          expect_metric_value(metrics, 'kernel_livepatch_loaded', 1.0, labels)
          expect_metric_value(metrics, 'kernel_livepatch_transition', 0.0, labels)
        end

        if entries.empty?
          expect(metrics).not_to include('kernel_livepatch_required')
          expect(metrics).not_to include('kernel_livepatch_loaded')
          expect(metrics).not_to include('kernel_livepatch_transition')
          expect(metrics).not_to include(
            'kernel_protection_monitoring_success{component="livepatch"}'
          )
        else
          expect_metric_value(
            metrics,
            'kernel_protection_monitoring_success',
            1.0,
            component: 'livepatch'
          )
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
      config =
        { pkgs, ... }:
        let
          missingLivepatchMonitor = pkgs.writeText "missing-livepatch-monitor.json" (
            builtins.toJSON {
              module = "missing_livepatch_test";
              patchVersion = 999;
            }
          );
          isolatedPumaConfig = pkgs.writeText "isolated-osctl-exporter-puma.rb" ''
            bind 'tcp://127.0.0.1:9102'
            rackup '${pkgs.osctl-exporter}/config.ru'
            environment 'production'
            tag 'isolated-osctl-exporter'
          '';
          isolatedExporter = pkgs.writeShellScriptBin "prometheus-test-isolated-osctl-exporter" ''
            set -eu

            test "$#" -ge 1
            state_dir=$1

            if test "$#" -eq 1; then
              exec ${pkgs.util-linux}/bin/unshare \
                --mount \
                --propagation private \
                -- \
                "$0" "$state_dir" --inside-mount-namespace
            fi

            test "$#" -eq 2
            test "$2" = --inside-mount-namespace

            monitor_dir=/etc/vpsadminos
            monitor_path=$monitor_dir/livepatch-monitor.json
            exporter_pid=

            cleanup() {
              trap - EXIT HUP INT TERM

              if test -n "$exporter_pid"; then
                kill "$exporter_pid" 2>/dev/null || true
                wait "$exporter_pid" 2>/dev/null || true
              fi

              ${pkgs.util-linux}/bin/umount "$monitor_path" 2>/dev/null || true
              ${pkgs.util-linux}/bin/umount "$monitor_dir" 2>/dev/null || true
            }
            trap cleanup EXIT HUP INT TERM

            mount_namespace=$(${pkgs.coreutils}/bin/readlink /proc/self/ns/mnt)
            guest_mount_namespace=$(${pkgs.coreutils}/bin/readlink /proc/1/ns/mnt)
            test "$mount_namespace" != "$guest_mount_namespace"
            printf '%s\n' "$mount_namespace" > "$state_dir/mount-namespace"

            ${pkgs.util-linux}/bin/mount --make-rprivate /
            ${pkgs.util-linux}/bin/mount -t tmpfs -o mode=0755 tmpfs "$monitor_dir"
            : > "$monitor_path"
            ${pkgs.util-linux}/bin/mount --bind ${missingLivepatchMonitor} "$monitor_path"

            export PATH=${
              pkgs.lib.makeBinPath [
                pkgs.coreutils
                pkgs.util-linux
              ]
            }:${pkgs.osctl-exporter}/env/bin
            puma -C ${isolatedPumaConfig} &
            exporter_pid=$!
            printf '%s\n' "$exporter_pid" > "$state_dir/exporter.pid"
            wait "$exporter_pid"
          '';
        in
        {
          environment.systemPackages = [ isolatedExporter ];

          services.ebpf-livepatch = {
            enable = true;
            # Select a non-expiring program explicitly. The default set can be
            # empty after a mitigation ages out for the current kernel.
            programs.${bpfLivepatchProgram} = { };
          };
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
          require 'json'

          BPF_LIVEPATCH_PROGRAM = ${builtins.toJSON bpfLivepatchProgram}
          BPF_LIVEPATCH_PINS = ${builtins.toJSON bpfLivepatchPins}
          ISOLATED_EXPORTER = '/run/current-system/sw/bin/prometheus-test-isolated-osctl-exporter'
          ISOLATED_EXPORTER_STATE = '/run/prometheus-exporters-kernel-protection'
          ISOLATED_EXPORTER_PID = "#{ISOLATED_EXPORTER_STATE}/launcher.pid"
          ISOLATED_EXPORTER_LOG = "#{ISOLATED_EXPORTER_STATE}/exporter.log"
          PRIMARY_EXPORTER_SERVICE = '/service/prometheus-osctl-exporter'

          def active_runit_pid(status, service)
            match = status.match(
              /\Arun: #{Regexp.escape(service)}: \(pid ([1-9][0-9]*)\) [0-9]+s\n?\z/
            )
            raise ArgumentError, "service is not active: #{status.inspect}" unless match

            match[1]
          end

          def livepatch_monitor_digest
            machine.succeeds(
              'if test -f /etc/vpsadminos/livepatch-monitor.json; then ' \
              'sha256sum /etc/vpsadminos/livepatch-monitor.json | cut -d " " -f 1; ' \
              'else printf "absent\\n"; fi'
            )[1].strip
          end

          before(:suite) do
            machine.start unless machine.running?
            machine.wait_until_online
            machine.wait_for_osctl_pool('tank')
            machine.wait_for_service('ebpf-livepatch')
            machine.wait_for_service('prometheus-osctl-exporter')

            @selected_livepatches = livepatch_monitor_entries
            @primary_livepatch_monitor_digest = livepatch_monitor_digest
            machine.succeeds(
              "install -d -m 0700 #{ISOLATED_EXPORTER_STATE}; " \
              "test -z \"$(find #{ISOLATED_EXPORTER_STATE} -mindepth 1 -print -quit)\"; " \
              "nohup #{ISOLATED_EXPORTER} #{ISOLATED_EXPORTER_STATE} " \
              ">#{ISOLATED_EXPORTER_LOG} 2>&1 & " \
              "pid=$!; printf '%s\\n' \"$pid\" >#{ISOLATED_EXPORTER_PID}; " \
              "kill -0 \"$pid\""
            )
            machine.wait_until_succeeds(
              "test -s #{ISOLATED_EXPORTER_STATE}/exporter.pid; " \
              "test -s #{ISOLATED_EXPORTER_STATE}/mount-namespace; " \
              "curl -sSf http://127.0.0.1:9102/metrics >/dev/null"
            )
            primary_status = machine.succeeds("sv status #{PRIMARY_EXPORTER_SERVICE}")[1]
            primary_pid = active_runit_pid(primary_status, PRIMARY_EXPORTER_SERVICE)
            machine.succeeds(<<~SH)
              set -eu
              state=/run/prometheus-exporters-kernel-protection
              launcher_pid=$(cat "$state/launcher.pid")
              primary_pid=#{primary_pid}
              case "$launcher_pid" in
                *[!0-9]*) exit 1 ;;
              esac
              test "$launcher_pid" -gt 0
              test "$primary_pid" -gt 0
              isolated_namespace=$(readlink "/proc/$launcher_pid/ns/mnt")
              primary_namespace=$(readlink "/proc/$primary_pid/ns/mnt")
              guest_namespace=$(readlink /proc/1/ns/mnt)
              recorded_namespace=$(cat "$state/mount-namespace")
              test "$isolated_namespace" = "$recorded_namespace"
              test "$isolated_namespace" != "$guest_namespace"
              test "$isolated_namespace" != "$primary_namespace"
            SH
            expect(livepatch_monitor_digest).to eq(@primary_livepatch_monitor_digest)
          end

          after(:suite) do
            next unless machine.running?

            machine.succeeds(<<~'SH')
              set -eu
              state=/run/prometheus-exporters-kernel-protection
              pid_file="$state/launcher.pid"
              test -s "$pid_file"
              pid=$(cat "$pid_file")
              case "$pid" in
                *[!0-9]*) exit 1 ;;
              esac
              test -n "$pid"
              test -r "/proc/$pid/cmdline"
              tr '\0' '\n' < "/proc/$pid/cmdline" |
                grep -Eq '(^|/)prometheus-test-isolated-osctl-exporter$'
              kill -TERM "$pid"
              for _ in $(seq 1 100); do
                test ! -e "/proc/$pid" && break
                sleep 0.1
              done
              test ! -e "/proc/$pid"
              rm -rf "$state"
            SH
            expect(livepatch_monitor_digest).to eq(@primary_livepatch_monitor_digest)
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

            it 'exports the real selected kernel livepatch stack' do
              wait_until_block_succeeds(name: 'selected kernel livepatch metrics') do
                metrics = fetch_metrics(9101)
                expect(metrics).not_to include('module="missing_livepatch_test"')
                expect_livepatch_stack(metrics, @selected_livepatches)
              end
            end

            it 'isolates a required but unloaded livepatch fixture' do
              wait_until_block_succeeds(name: 'isolated kernel livepatch metrics') do
                isolated_metrics = fetch_metrics(9102)
                labels = {
                  module: 'missing_livepatch_test',
                  patch_version: '999'
                }
                expect_metric_value(
                  isolated_metrics,
                  'kernel_livepatch_required',
                  1.0,
                  labels
                )
                expect_metric_value(
                  isolated_metrics,
                  'kernel_livepatch_loaded',
                  0.0,
                  labels
                )
                expect_metric_value(
                  isolated_metrics,
                  'kernel_livepatch_transition',
                  0.0,
                  labels
                )
                expect_metric_value(
                  isolated_metrics,
                  'kernel_protection_monitoring_success',
                  1.0,
                  component: 'livepatch'
                )
                required_lines = isolated_metrics.lines.select do |line|
                  line.start_with?('kernel_livepatch_required{')
                end
                expect(required_lines.length).to eq(1)

                primary_metrics = fetch_metrics(9101)
                expect(primary_metrics).not_to include('module="missing_livepatch_test"')
                expect_livepatch_stack(primary_metrics, @selected_livepatches)
              end
            end
          end
        '';
      };
    };
  }
)
