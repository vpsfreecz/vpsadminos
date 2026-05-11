import ../../make-test.nix (
  { pkgs }:
  let
    crashdumpConfig = {
      boot.crashDump = {
        enable = true;
        kernelParams = [ "console=ttyS0" ];
        commands = ''
          echo "Dumping dmesg"
          if [ -e /proc/vmcore ] ; then
            ls -l /proc/vmcore
          else
            echo "/proc/vmcore is missing"
          fi

          makedumpfile --dump-dmesg /proc/vmcore dmesg.log
          rc=$?
          echo "makedumpfile exited with $rc"

          if [ -e dmesg.log ] ; then
            ls -l dmesg.log
            cat dmesg.log
          else
            echo "dmesg.log is missing"
          fi

          # Bring the machine down, so that machine.execute() will raise OsVm::MachineShellClosed
          reboot -f
        '';
      };
    };

    pigzSystem =
      (import ../../../os {
        importedPkgs = pkgs;
        system = pkgs.system;
        modules = [
          ../../configs/vpsadminos/base.nix
          ../../configs/vpsadminos/pool-tank.nix
          crashdumpConfig
          {
            boot.initrd.compressor = "pigz";
          }
        ];
      }).config.system.build.toplevel;
  in
  {
    name = "crashdump-default";

    description = ''
      Test that the default crashdump initrd stays lean and the crash kernel can
      read kernel log
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = crashdumpConfig // {
        system.extraDependencies = [ pigzSystem ];
      };
    };

    testScript = ''
      message = 'hello crash kernel test'

      def self.expect_crash_kernel_loaded(test_machine)
        _, loaded = test_machine.succeeds('cat /sys/kernel/kexec_crash_loaded')

        if loaded.strip != '1'
          test_machine.succeeds('sv status crashdump || true')
          test_machine.succeeds('tail -n 200 /var/log/crashdump/current || true')
          test_machine.succeeds('dmesg | grep -Ei "crash|kexec|reserve|memory" || true')
        end

        expect(loaded.strip).to eq('1')
      end

      describe 'crashdump default', order: :defined do
        it 'boots and prepares containers' do
          machine.start

          # We create containers to test that syslog namespace will not disrupt
          # dumping of kernel log from the host
          machine.wait_for_osctl_pool('tank')

          3.times do
            testct = get_container_id

            machine.all_succeed(
              "osctl ct new --distribution #{%w[almalinux alpine arch debian ubuntu].sample} #{testct}",
              "osctl ct start #{testct}"
            )
          end

          sleep(5)

          machine.wait_for_service('crashdump')
        end

        it 'uses the regular initrd as crash initrd' do
          _, initrd_real = machine.succeeds('readlink -f /run/current-system/initrd')
          _, crash_initrd_real = machine.succeeds('readlink -f /run/current-system/crash-initrd')

          expect(crash_initrd_real.strip).to eq(initrd_real.strip)
        end

        it 'restarts crashdump when the crash initrd changes' do
          _, current_run = machine.succeeds('readlink -f /etc/runit/services/crashdump/run')
          _, pigz_run = machine.succeeds('readlink -f ${pigzSystem}/etc/runit/services/crashdump/run')

          expect(pigz_run.strip).to eq(current_run.strip)

          _, current_initrd = machine.succeeds('readlink -f /run/current-system/crash-initrd')
          _, pigz_initrd = machine.succeeds('readlink -f ${pigzSystem}/crash-initrd')

          expect(pigz_initrd.strip).not_to eq(current_initrd.strip)

          _, output = machine.succeeds('${pigzSystem}/bin/switch-to-configuration dry-activate')

          expect(output).to include('> sv stop crashdump')
          expect(output).to include('> sv start crashdump')
        end

        it 'does not include crash inspection helpers' do
          _, base_listing = machine.succeeds(
            "${pkgs.coreutils}/bin/cat /run/current-system/crash-initrd | ${pkgs.zstd}/bin/zstd -dc | ${pkgs.cpio}/bin/cpio -it 2>/dev/null"
          )

          expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash(\n|$)})
          expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-vmcore(\n|$)})
          expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-collect(\n|$)})
          expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-report(\n|$)})
          expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-continue(\n|$)})
        end

        it 'does not build a crash debug overlay' do
          machine.fails('test -e /run/crashdump/overlay/.crash/manifest')
        end

        it 'loads the crash kernel and dumps dmesg' do
          expect_crash_kernel_loaded(machine)
          machine.execute("echo #{message} > /dev/kmsg")

          begin
            machine.execute('echo c > /proc/sysrq-trigger')
          rescue OsVm::MachineShellClosed
            # pass
          else
            fail 'Expected machine shell to be closed'
          end

          # At this point, the machine is down and the console output is complete
          timeout = 1

          machine.wait_for_console_text(/sysrq: Trigger a crash/, timeout:)
          machine.wait_for_console_text(/Kernel panic - not syncing: sysrq triggered crash/, timeout:)
          machine.wait_for_console_text(/This is a crash kernel/, timeout:)
          machine.wait_for_console_text(/Dumping dmesg/, timeout:)
          machine.wait_for_console_text(/makedumpfile exited with 0/, timeout:)
          machine.wait_for_console_text(/#{Regexp.escape(message)}/, timeout:)
        end
      end
    '';
  }
)
