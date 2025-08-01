import ../make-test.nix (
  { pkgs }:
  {
    name = "crashdump";

    description = ''
      Test that crash kernel can read kernel log
    '';

    tags = [ "ci" ];

    machine = import ../machines/with-tank.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          boot.crashDump = {
            enable = true;
            kernelParams = [ "console=ttyS0" ];
            commands = ''
              echo "Dumping dmesg"
              makedumpfile --dump-dmesg /proc/vmcore dmesg.log
              cat dmesg.log

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
      machine.wait_for_console_text(/#{Regexp.escape(message)}/, timeout:)
    '';
  }
)
