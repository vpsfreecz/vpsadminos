import ../make-test.nix ({ pkgs }: {
  name = "crashdump";

  description = ''
    Test that crash kernel can read kernel log
  '';

  tags = [ "ci" ];

  machine = import ../machines/with-empty.nix {
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
    machine.wait_for_boot
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
    machine.wait_for_console_text(/sysrq: Trigger a crash/, timeout: 1)
    machine.wait_for_console_text(/Kernel panic - not syncing: sysrq triggered crash/, timeout: 1)
    machine.wait_for_console_text(/This is a crash kernel/, timeout: 1)
    machine.wait_for_console_text(/Dumping dmesg/, timeout: 1)
    machine.wait_for_console_text(/#{Regexp.escape(message)}/, timeout: 1)
  '';
})
