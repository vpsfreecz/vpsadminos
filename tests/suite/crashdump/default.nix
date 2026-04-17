import ../../make-test.nix (
  { pkgs }:
  {
    name = "crashdump-default";

    description = ''
      Test that the default crashdump initrd stays lean and the crash kernel can
      read kernel log
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
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
    };

    testScript = ''
      message = 'hello crash kernel test'
      machine.start

      # We create containers to test that syslog namespace will not distrupt
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

      _, initrd_real = machine.succeeds('readlink -f /run/current-system/initrd')
      _, crash_initrd_real = machine.succeeds('readlink -f /run/current-system/crash-initrd')
      expect(crash_initrd_real.strip).to eq(initrd_real.strip)

      _, base_listing = machine.succeeds(
        "${pkgs.gzip}/bin/gzip -dc /run/current-system/crash-initrd | ${pkgs.cpio}/bin/cpio -it 2>/dev/null"
      )
      expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash(\n|$)})
      expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-vmcore(\n|$)})
      expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-collect(\n|$)})
      expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-report(\n|$)})
      expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-continue(\n|$)})

      machine.fails('test -e /run/crashdump/overlay/.crash/manifest')

      _, loaded = machine.succeeds('cat /sys/kernel/kexec_crash_loaded')
      expect(loaded.strip).to eq('1')

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
    '';
  }
)
