import ../../make-test.nix (
  { pkgs }:
  let
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
    name = "crashdump-equivalence";

    description = ''
      Compare normalized legacy and optimized reports from one vmcore with
      512 synthetic sleeping processes
    '';

    tags = [ "crashdump-equivalence" ];

    labels = {
      component = "crashdump";
      runtime = "long";
      gate = "manual";
    };

    machine =
      (import ../../machines/vpsadminos/with-empty.nix {
        inherit pkgs;
        config =
          { ... }:
          {
            environment.systemPackages = [
              pkgs.e2fsprogs
              processFarm
            ];

            boot.initrd = {
              kernelModules = [ "ext4" ];
              extraUtilsCommands = ''
                copy_bin_and_libs ${legacyCrash}/bin/crash-legacy
                copy_bin_and_libs ${pkgs.diffutils}/bin/diff
                cp ${./legacy-crash-collect} $out/bin/crash-collect-legacy
                chmod +x $out/bin/crash-collect-legacy
              '';
            };

            boot.crashDump = {
              enable = true;
              inspect.enable = true;
              kernelParams = [ "console=ttyS0" ];
              commands = ''
                mkdir -p /mnt/reports
                mount -t ext4 /dev/sda /mnt/reports \
                  || fail "Unable to mount report disk"

                crash-collect-legacy /mnt/reports/legacy \
                  || fail "Legacy collector failed"
                crash-collect /mnt/reports/optimized \
                  || fail "Optimized collector failed"

                [ "$(awk '$2 == 0 { count++ } END { print count + 0 }' \
                  /mnt/reports/legacy/status)" = 11 ] \
                  || fail "Legacy collector did not complete all reports"
                [ "$(awk '$2 == 0 { count++ } END { print count + 0 }' \
                  /mnt/reports/optimized/status)" = 11 ] \
                  || fail "Optimized collector did not complete all reports"

                for report in \
                  sys.txt log.txt ps.txt ps-summary.txt ps-last-run.txt \
                  ps-active.txt bt-panic.txt bt-active.txt \
                  bt-active-nonidle.txt bt-sleeping-interruptible.txt \
                  bt-sleeping-uninterruptible.txt ; do
                  for collector in legacy optimized ; do
                    awk '
                      started || /^crash(-legacy)?> / {
                        started = 1
                        sub(/^crash-legacy> /, "crash> ")
                        if ($0 == "crash> quit")
                          next
                        sub(/ \| crash-buffer .*/, "")
                        print
                      }
                    ' "/mnt/reports/$collector/$report" \
                      > "/mnt/reports/$collector/$report.normalized"
                  done

                  diff -u \
                    "/mnt/reports/legacy/$report.normalized" \
                    "/mnt/reports/optimized/$report.normalized" \
                    || fail "Report differs: $report"
                done

                echo "Legacy and optimized reports are equivalent"
                sync
                reboot -f
              '';
            };
          };
      })
      // {
        disks = [
          {
            type = "file";
            device = "{machine}-reports.img";
            size = "4G";
          }
        ];
      };

    testScript = ''
      timeout = 45 * 60

      def self.expect_crash_kernel_loaded(test_machine)
        _, loaded = test_machine.succeeds('cat /sys/kernel/kexec_crash_loaded')

        if loaded.strip != '1'
          test_machine.succeeds('sv status crashdump || true')
          test_machine.succeeds('tail -n 200 /var/log/crashdump/current || true')
          test_machine.succeeds('dmesg | grep -Ei "crash|kexec|reserve|memory" || true')
        end

        expect(loaded.strip).to eq('1')
      end

      machine.start
      machine.wait_until_online
      machine.succeeds('mkfs.ext4 -F /dev/sda', timeout: 120)
      machine.succeeds(
        'rm -f /run/crash-process-farm.ready /run/crash-process-farm.log; ' \
        'crash-process-farm 512 /run/crash-process-farm.ready ' \
        '> /run/crash-process-farm.log 2>&1 &'
      )
      machine.wait_until_succeeds(
        "test \"$(cat /run/crash-process-farm.ready)\" = 512",
        timeout: 120
      )
      machine.wait_for_service('crashdump')
      expect_crash_kernel_loaded(machine)

      machine.allow_kernel_failure(/Kernel panic - not syncing: sysrq triggered crash/) do
        begin
          machine.execute('echo c > /proc/sysrq-trigger', timeout:)
        rescue OsVm::MachineShellClosed
        else
          fail 'Expected machine shell to be closed'
        end

        machine.wait_for_console_text(/This is a crash kernel/, timeout:)
        machine.wait_for_console_text(
          /Legacy and optimized reports are equivalent/,
          timeout:
        )
        machine.wait_for_shutdown(timeout: 120)
      end
    '';
  }
)
