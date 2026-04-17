import ../../make-test.nix (
  { pkgs }:
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

              echo "Inspection output"
              find inspect -maxdepth 1 -type f | sort
              for f in \
                inspect/README \
                inspect/manifest \
                inspect/status \
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

      machine.wait_for_service('crashdump')

      _, initrd_real = machine.succeeds('readlink -f /run/current-system/initrd')
      _, crash_initrd_real = machine.succeeds('readlink -f /run/current-system/crash-initrd')
      expect(crash_initrd_real.strip).to eq(initrd_real.strip)

      _, base_listing = machine.succeeds(
        "${pkgs.gzip}/bin/gzip -dc /run/current-system/crash-initrd | ${pkgs.cpio}/bin/cpio -it 2>/dev/null"
      )
      expect(base_listing).to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash(\n|$)})
      expect(base_listing).to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-vmcore(\n|$)})
      expect(base_listing).to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-collect(\n|$)})
      expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-report(\n|$)})
      expect(base_listing).not_to match(%r{(^|\n)nix/store/.+-extra-utils/bin/crash-continue(\n|$)})
      expect(base_listing).to match(%r{(^|\n)nix/store/.+-extra-utils/share/terminfo/l/linux(\n|$)})

      _, overlay_listing = machine.succeeds(
        "${pkgs.gzip}/bin/gzip -dc /run/crashdump/crash-debug.cpio.gz | ${pkgs.cpio}/bin/cpio -it 2>/dev/null"
      )
      expect(overlay_listing).to include('.crash/System.map')
      expect(overlay_listing).to include('.crash/vmlinux.gz')
      expect(overlay_listing).to include('.crash/vmlinux.sha256')
      expect(overlay_listing).to include('.crash/manifest')

      _, manifest = machine.succeeds('cat /run/crashdump/overlay/.crash/manifest')
      expect(manifest).to include('booted_debug=/run/booted-system/crash-debug')
      expect(manifest).to include("base_initrd=#{crash_initrd_real.strip}")

      _, booted_sha = machine.succeeds('cat /run/booted-system/crash-debug/vmlinux.sha256')
      _, overlay_sha = machine.succeeds('cat /run/crashdump/overlay/.crash/vmlinux.sha256')
      expect(overlay_sha.strip).to eq(booted_sha.strip)

      _, loaded = machine.succeeds('cat /sys/kernel/kexec_crash_loaded')
      expect(loaded.strip).to eq('1')

      machine.execute("echo #{message} > /dev/kmsg")

      begin
        machine.execute('echo c > /proc/sysrq-trigger')
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
      machine.wait_for_console_text(/inspect\/README/, timeout:)
      machine.wait_for_console_text(/inspect\/ps-active.txt/, timeout:)
      machine.wait_for_console_text(/inspect\/bt-active.txt/, timeout:)
      machine.wait_for_console_text(/inspect\/bt-sleeping-interruptible.txt/, timeout:)
      machine.wait_for_console_text(/inspect\/bt-sleeping-uninterruptible.txt/, timeout:)
      machine.wait_for_console_text(/Dumping dmesg/, timeout:)
      machine.wait_for_console_text(/#{Regexp.escape(message)}/, timeout:)
    '';
  }
)
