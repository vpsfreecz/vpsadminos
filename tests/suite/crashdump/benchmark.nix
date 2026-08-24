import ../../make-template.nix (
  {
    collector,
    run,
  }:
  let
    instance = "${collector}-${toString run}";
  in
  assert builtins.elem collector [
    "legacy"
    "optimized"
  ];
  assert run >= 1 && run <= 3;
  {
    inherit instance;

    test =
      { pkgs }:
      let
        lib = pkgs.lib;
        network = [
          { type = "user"; }
          { type = "socket"; }
        ];
        serverAddress = "192.168.10.12";
        crasherAddress = "192.168.10.11";
        exportPath = "/storage/vpsfree.cz/crashdump";
        collectorProgram = if collector == "legacy" then "crash-collect-legacy" else "crash-collect";
        sourceRevision =
          let
            revision = builtins.getEnv "TEST_RUNNER_REPO_REV";
          in
          if revision == "" then "working-tree" else revision;

        processFarm = import ./process-farm.nix { inherit pkgs; };

        unpatchedCrash = (pkgs.callPackage ../../../os/packages/crash/default.nix { }).overrideAttrs (_: {
          patches = [ ];
        });
        legacyCrash = pkgs.runCommand "crash-legacy-9.0.1" { } ''
          mkdir -p $out/bin
          cp ${unpatchedCrash}/bin/crash $out/bin/crash-legacy
        '';
      in
      {
        name = "crashdump-benchmark@${instance}";

        description = ''
          Benchmark ${collector} crash inspection run ${toString run} with
          5,000 synthetic sleeping processes and NFS-backed report output
        '';

        tags = [ "crashdump-benchmark" ];

        labels = {
          component = "crashdump";
          runtime = "long";
          gate = "manual";
          inherit collector;
          benchmark_run = toString run;
        };

        machines = {
          server =
            (import ../../machines/vpsadminos/with-tank.nix {
              inherit pkgs;
              config =
                {
                  lib,
                  ...
                }:
                {
                  networking.hostName = "server";
                  networking.custom = ''
                    ip addr add ${serverAddress}/24 dev eth1
                    ip link set eth1 up
                  '';

                  boot.qemu = {
                    memory = lib.mkForce 4096;
                    cpus = lib.mkForce 2;
                    cpu = {
                      cores = lib.mkForce 2;
                      threads = lib.mkForce 1;
                      sockets = lib.mkForce 1;
                    };
                  };

                  services.nfs.server = {
                    enable = true;
                    nfsd.port = 2049;
                    mountdPort = 20048;
                    statdPort = 662;
                    lockdPort = 32769;
                  };

                  networking.firewall.allowedTCPPorts = [
                    111
                    662
                    2049
                    20048
                    32769
                  ];
                  networking.firewall.allowedUDPPorts = [
                    111
                    662
                    2049
                    20048
                    32769
                  ];

                  boot.zfs.pools.tank.datasets."vpsfree.cz/crashdump".properties = {
                    mountpoint = exportPath;
                    sharenfs = "rw=${crasherAddress}/32,no_root_squash";
                  };
                };
            })
            // {
              networks = network;
            };

          crasher =
            (import ../../machines/vpsadminos/with-empty.nix {
              inherit pkgs;
              config =
                {
                  lib,
                  ...
                }:
                {
                  networking.hostName = "crasher";
                  networking.custom = ''
                    ip addr add ${crasherAddress}/24 dev eth1
                    ip link set eth1 up
                  '';

                  boot.qemu = {
                    memory = lib.mkForce 8192;
                    cpus = lib.mkForce 4;
                    cpu = {
                      cores = lib.mkForce 4;
                      threads = lib.mkForce 1;
                      sockets = lib.mkForce 1;
                    };
                  };

                  environment.systemPackages = [ processFarm ];

                  boot.kernelModules = [
                    "lockd"
                    "netfs"
                    "nfs"
                    "nfsv4"
                    "sunrpc"
                  ];

                  boot.initrd = {
                    kernelModules = [
                      "lockd"
                      "netfs"
                      "nfs"
                      "nfsv4"
                      "sunrpc"
                    ];

                    network = {
                      enable = true;
                      useDHCP = false;
                      setClock = false;
                      customSetupCommands = ''
                        if grep -q this_is_a_crash_kernel /proc/cmdline ; then
                          ip addr add ${crasherAddress}/24 dev eth1
                          ip link set eth1 up
                        fi
                      '';
                    };

                    extraUtilsCommands = ''
                      copy_bin_and_libs ${pkgs.nfs-utils}/bin/mount.nfs
                      ${lib.optionalString (collector == "legacy") ''
                        copy_bin_and_libs ${legacyCrash}/bin/crash-legacy
                        cp ${./legacy-crash-collect} $out/bin/crash-collect-legacy
                        chmod +x $out/bin/crash-collect-legacy
                      ''}
                    '';
                  };

                  boot.crashDump = {
                    enable = true;
                    reservedMemory = "2048M";
                    inspect.enable = true;
                    kernelParams = [ "console=ttyS0" ];
                    commands = ''
                      now_ms() {
                        awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime
                      }

                      mountpoint=/mnt/crashdump
                      target="$mountpoint/benchmark/${instance}"
                      server=${serverAddress}:${exportPath}

                      mkdir -p "$mountpoint"
                      mount.nfs -o vers=4 "$server" "$mountpoint" \
                        || fail "Unable to mount benchmark NFS share"
                      mkdir -p "$target/inspect"

                      makedumpfile --dump-dmesg /proc/vmcore "$target/dmesg" \
                        || fail "Unable to dump dmesg"
                      sync

                      collect_start_ms=$(now_ms)
                      ${collectorProgram} "$target/inspect"
                      collect_rc=$?
                      sync
                      collect_end_ms=$(now_ms)

                      actual_tasks=$(grep -c 'crash-load' \
                        "$target/inspect/ps-last-run.txt")
                      output_bytes=$(du -sb "$target/inspect" | awk '{print $1}')

                      cat > "$target/result" <<EOF_RESULT
                      collector=${collector}
                      run=${toString run}
                      revision=${sourceRevision}
                      synthetic_tasks=5000
                      actual_tasks=$actual_tasks
                      collect_sync_ms=$((collect_end_ms - collect_start_ms))
                      collector_exit_status=$collect_rc
                      output_bytes=$output_bytes
                      vm_cpus=4
                      vm_memory_mib=8192
                      crash_reserved_memory_mib=2048
                      EOF_RESULT
                      sync

                      [ "$collect_rc" = 0 ] || fail "Collector failed"
                      [ "$actual_tasks" -ge 5000 ] \
                        || fail "Expected at least 5,000 crash-load rows"

                      echo "Benchmark collection complete"
                      reboot -f
                    '';
                  };
                };
            })
            // {
              networks = network;
            };
        };

        testScript = ''
          require 'shellwords'

          export_path = ${builtins.toJSON exportPath}
          target = File.join(export_path, 'benchmark', ${builtins.toJSON instance})
          timeout = 90 * 60

          def self.expect_crash_kernel_loaded(test_machine)
            _, loaded = test_machine.succeeds('cat /sys/kernel/kexec_crash_loaded')

            if loaded.strip != '1'
              test_machine.succeeds('sv status crashdump || true')
              test_machine.succeeds('tail -n 200 /var/log/crashdump/current || true')
              test_machine.succeeds('dmesg | grep -Ei "crash|kexec|reserve|memory" || true')
            end

            expect(loaded.strip).to eq('1')
          end

          server.start
          server.wait_for_osctl_pool('tank')
          server.wait_for_service('nfsd')
          server.wait_until_succeeds(
            "test -d #{Shellwords.escape(export_path)}",
            timeout: 120
          )
          server.succeeds('zfs share -a', timeout: 60)

          crasher.start
          crasher.wait_for_service('crashdump')
          expect_crash_kernel_loaded(crasher)
          crasher.succeeds(
            'rm -f /run/crash-process-farm.ready /run/crash-process-farm.log; ' \
            'crash-process-farm 5000 /run/crash-process-farm.ready ' \
            '> /run/crash-process-farm.log 2>&1 &'
          )
          crasher.wait_until_succeeds(
            "test \"$(cat /run/crash-process-farm.ready)\" = 5000",
            timeout: 10 * 60
          )
          _, process_count = crasher.succeeds(
            'pgrep -xc crash-load'
          )
          expect(process_count.to_i).to be >= 5000

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          crasher.allow_kernel_failure(/Kernel panic - not syncing: sysrq triggered crash/) do
            begin
              crasher.execute('echo c > /proc/sysrq-trigger', timeout:)
            rescue OsVm::MachineShellClosed
            else
              fail 'Expected machine shell to be closed'
            end

            crasher.wait_for_console_text(/This is a crash kernel/, timeout:)
            crasher.wait_for_console_text(/Benchmark collection complete/, timeout:)
            crasher.wait_for_shutdown(timeout: 120)
          end

          panic_to_reboot_ms = (
            (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000
          ).round
          host_cpu = File.foreach('/proc/cpuinfo').find { |line| line.start_with?('model name') }
            &.split(':', 2)&.last&.strip || 'unknown'

          server.wait_until_succeeds(
            "test -s #{Shellwords.escape(File.join(target, 'result'))}",
            timeout: 120
          )
          server.succeeds(
            "printf '%s\\n' " \
            "#{Shellwords.escape("panic_to_reboot_ms=#{panic_to_reboot_ms}")} " \
            "#{Shellwords.escape("host_cpu=#{host_cpu}")} " \
            ">> #{Shellwords.escape(File.join(target, 'result'))}"
          )

          result = server.succeeds("cat #{Shellwords.escape(File.join(target, 'result'))}")[1]
          values = result.lines.to_h { |line| line.strip.split('=', 2) }

          expect(values.fetch('collector_exit_status')).to eq('0')
          expect(values.fetch('actual_tasks').to_i).to be >= 5000
          expect(values.fetch('collect_sync_ms').to_i).to be > 0
          expect(values.fetch('panic_to_reboot_ms').to_i).to be > 0

          puts [
            'BENCHMARK',
            "collector=#{values.fetch('collector')}",
            "run=#{values.fetch('run')}",
            "revision=#{values.fetch('revision')}",
            "synthetic_tasks=#{values.fetch('synthetic_tasks')}",
            "actual_tasks=#{values.fetch('actual_tasks')}",
            "collect_sync_ms=#{values.fetch('collect_sync_ms')}",
            "panic_to_reboot_ms=#{values.fetch('panic_to_reboot_ms')}",
            "output_bytes=#{values.fetch('output_bytes')}",
            "host_cpu=#{values.fetch('host_cpu')}"
          ].join(' ')
        '';
      };
  }
)
