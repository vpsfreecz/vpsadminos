import ../../make-test.nix (
  { pkgs }:
  let
    processFarm = import ./process-farm.nix { inherit pkgs; };
  in
  {
    name = "crashdump-inspect";

    description = ''
      Test that optional crash inspection adds the required initrd helpers,
      composes the debug overlay from the booted system and can inspect
      /proc/vmcore using crash(8)
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          environment.systemPackages = [ processFarm ];

          boot.crashDump = {
            enable = true;
            inspect.enable = true;
            kernelParams = [ "console=ttyS0" ];
            commands = ''
              echo "Inspecting crash vmcore"
              if [ -e /proc/vmcore ] ; then
                ls -l /proc/vmcore
              else
                echo "/proc/vmcore is missing"
              fi

              echo "Running crash-collect"
              crash-collect inspect
              rc=$?
              echo "crash-collect exited with $rc"
              [ "$rc" = 0 ] || fail "crash-collect failed"

              expected_reports=11
              completed_reports=$(awk '$2 == 0 { count++ } END { print count + 0 }' inspect/status)
              [ "$completed_reports" = "$expected_reports" ] \
                || fail "Expected $expected_reports complete reports, got $completed_reports"

              crash_load_bt=$(grep -c 'crash-load' inspect/bt-sleeping-interruptible.txt)
              crash_load_ps=$(grep -c 'crash-load' inspect/ps-last-run.txt)
              echo "crash-load interruptible backtraces: $crash_load_bt"
              echo "crash-load last-run rows: $crash_load_ps"
              [ "$crash_load_bt" -ge 512 ] \
                || fail "Expected at least 512 crash-load backtraces"
              [ "$crash_load_ps" -ge 512 ] \
                || fail "Expected at least 512 crash-load ps -m rows"
              ! grep -q 'crash-load' inspect/ps-active.txt \
                || fail "ps -A contains sleeping crash-load processes"

              [ "$(grep -c '^crash 9\.0\.1' inspect/session.txt)" = 1 ] \
                || fail "Expected one crash initialization"
              ! grep -l '^crash 9\.0\.1' inspect/*.txt \
                | grep -v '/session.txt$' \
                || fail "Report contains a repeated crash initialization"

              for timing in \
                initialization session collector sys.txt log.txt ps.txt \
                ps-summary.txt ps-last-run.txt ps-active.txt bt-panic.txt \
                bt-active.txt bt-active-nonidle.txt \
                bt-sleeping-interruptible.txt \
                bt-sleeping-uninterruptible.txt ; do
                grep -Eq "^$timing [0-9]+$" inspect/timings \
                  || fail "Missing timing for $timing"
              done

              for report in \
                sys.txt log.txt ps.txt ps-summary.txt ps-last-run.txt \
                ps-active.txt bt-panic.txt bt-active.txt \
                bt-active-nonidle.txt bt-sleeping-interruptible.txt \
                bt-sleeping-uninterruptible.txt ; do
                printf 'stale report\n' > "inspect/$report"
              done

              if CRASH_VMLINUX=/missing crash-collect inspect ; then
                fail "Retry with missing vmlinux unexpectedly succeeded"
              fi

              for report in \
                sys.txt log.txt ps.txt ps-summary.txt ps-last-run.txt \
                ps-active.txt bt-panic.txt bt-active.txt \
                bt-active-nonidle.txt bt-sleeping-interruptible.txt \
                bt-sleeping-uninterruptible.txt ; do
                [ ! -s "inspect/$report" ] \
                  || fail "Retry left stale report data in $report"
              done

              failed_reports=$(awk '$2 != 0 { count++ } END { print count + 0 }' inspect/status)
              [ "$failed_reports" = "$expected_reports" ] \
                || fail "Retry did not mark every report failed"
              echo "Failed retry cleared all stale reports"

              echo "Inspection output"
              find inspect -maxdepth 1 -type f | sort
              for f in \
                inspect/README \
                inspect/manifest \
                inspect/status \
                inspect/timings \
                inspect/session.txt \
                inspect/ps-active.txt \
                inspect/bt-active.txt \
                inspect/bt-sleeping-interruptible.txt \
                inspect/bt-sleeping-uninterruptible.txt ; do
                if [ -e "$f" ] ; then
                  echo "=== $f ==="
                  sed -n '1,80p' "$f"
                else
                  echo "$f is missing"
                fi
              done

              echo "Dumping dmesg"
              makedumpfile --dump-dmesg /proc/vmcore dmesg.log
              rc=$?
              echo "makedumpfile exited with $rc"

              if [ -e dmesg.log ] ; then
                ls -l dmesg.log
                cat dmesg.log
              else
                echo "dmesg.log is missing"
              fi

              reboot -f
            '';
          };
        };
    };

    testScript = ''
      message = 'hello crash kernel inspect test'
      crash_command_timeout = 20 * 60

      def self.expect_crash_kernel_loaded(test_machine)
        _, loaded = test_machine.succeeds('cat /sys/kernel/kexec_crash_loaded')

        if loaded.strip != '1'
          test_machine.succeeds('sv status crashdump || true')
          test_machine.succeeds('tail -n 200 /var/log/crashdump/current || true')
          test_machine.succeeds('dmesg | grep -Ei "crash|kexec|reserve|memory" || true')
        end

        expect(loaded.strip).to eq('1')
      end

      describe 'crashdump inspect', order: :defined do
        it 'boots and prepares containers' do
          machine.start

          machine.wait_for_osctl_pool('tank')

          3.times do
            testct = get_container_id

            machine.all_succeed(
              "osctl ct new --distribution #{%w[almalinux alpine arch debian ubuntu].sample} #{testct}",
              "osctl ct start #{testct}"
            )
          end

          sleep(5)

          machine.succeeds(
            'rm -f /run/crash-process-farm.ready /run/crash-process-farm.log; ' \
            'crash-process-farm 512 /run/crash-process-farm.ready ' \
            '> /run/crash-process-farm.log 2>&1 &'
          )
          machine.wait_until_succeeds(
            "test \"$(cat /run/crash-process-farm.ready)\" = 512",
            timeout: 120
          )
          _, process_count = machine.succeeds(
            'pgrep -xc crash-load'
          )
          expect(process_count.to_i).to be >= 512

          machine.wait_for_service('crashdump')
        end

        it 'uses the regular initrd as crash initrd' do
          _, initrd_real = machine.succeeds('readlink -f /run/current-system/initrd')
          _, crash_initrd_real = machine.succeeds('readlink -f /run/current-system/crash-initrd')

          expect(crash_initrd_real.strip).to eq(initrd_real.strip)
        end

        it 'includes crash inspection helpers' do
          _, base_listing = machine.succeeds(
            "${pkgs.coreutils}/bin/cat /run/current-system/crash-initrd | ${pkgs.zstd}/bin/zstd -dc | ${pkgs.cpio}/bin/cpio -it 2>/dev/null"
          )

          expect(base_listing).to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash(\n|$)})
          expect(base_listing).to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-vmcore(\n|$)})
          expect(base_listing).to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-collect(\n|$)})
          expect(base_listing).to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-buffer(\n|$)})
          expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-report(\n|$)})
          expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-continue(\n|$)})
          expect(base_listing).to match(%r{(^|\n)nix/store/.+-extra-utils/share/terminfo/l/linux(\n|$)})
        end

        it 'builds a crash debug overlay' do
          _, overlay_listing = machine.succeeds(
            "${pkgs.gzip}/bin/gzip -dc /run/crashdump/crash-debug.cpio.gz | ${pkgs.cpio}/bin/cpio -it 2>/dev/null"
          )

          expect(overlay_listing).to include('.crash/System.map')
          expect(overlay_listing).to include('.crash/vmlinux.gz')
          expect(overlay_listing).to include('.crash/vmlinux.sha256')
          expect(overlay_listing).to include('.crash/manifest')
        end

        it 'records the booted debug overlay in its manifest' do
          _, crash_initrd_real = machine.succeeds('readlink -f /run/current-system/crash-initrd')
          _, manifest = machine.succeeds('cat /run/crashdump/overlay/.crash/manifest')

          expect(manifest).to include('booted_debug=/run/booted-system/crash-debug')
          expect(manifest).to include("base_initrd=#{crash_initrd_real.strip}")
        end

        it 'uses the booted vmlinux in the crash debug overlay' do
          _, booted_sha = machine.succeeds('cat /run/booted-system/crash-debug/vmlinux.sha256')
          _, overlay_sha = machine.succeeds('cat /run/crashdump/overlay/.crash/vmlinux.sha256')

          expect(overlay_sha.strip).to eq(booted_sha.strip)
        end

        it 'loads the crash kernel and collects inspection output' do
          expect_crash_kernel_loaded(machine)
          machine.execute("echo #{message} > /dev/kmsg")

          machine.allow_kernel_failure(/Kernel panic - not syncing: sysrq triggered crash/) do
            begin
              machine.execute('echo c > /proc/sysrq-trigger', timeout: crash_command_timeout)
            rescue OsVm::MachineShellClosed
            else
              fail 'Expected machine shell to be closed'
            end

            timeout = 1

            machine.wait_for_console_text(/sysrq: Trigger a crash/, timeout:)
            machine.wait_for_console_text(/Kernel panic - not syncing: sysrq triggered crash/, timeout:)
            machine.wait_for_console_text(/This is a crash kernel/, timeout:)
            machine.wait_for_console_text(/Running crash-collect/, timeout:)
            machine.wait_for_console_text(/crash-collect exited with 0/, timeout:)
            machine.wait_for_console_text(/crash-load interruptible backtraces: 5[1-9][0-9]/, timeout:)
            machine.wait_for_console_text(/Failed retry cleared all stale reports/, timeout:)
            machine.wait_for_console_text(/inspect\/README/, timeout:)
            machine.wait_for_console_text(/inspect\/ps-active.txt/, timeout:)
            machine.wait_for_console_text(/inspect\/bt-active.txt/, timeout:)
            machine.wait_for_console_text(/inspect\/bt-sleeping-interruptible.txt/, timeout:)
            machine.wait_for_console_text(/inspect\/bt-sleeping-uninterruptible.txt/, timeout:)
            machine.wait_for_console_text(/Dumping dmesg/, timeout:)
            machine.wait_for_console_text(/#{Regexp.escape(message)}/, timeout:)
          end
        end
      end
    '';
  }
)
