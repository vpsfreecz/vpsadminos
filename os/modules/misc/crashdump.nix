{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    any
    concatStringsSep
    filter
    hasPrefix
    mkIf
    mkOption
    optional
    optionalAttrs
    optionalString
    types
    ;

  cfg = config.boot.crashDump;

  makedumpfile = pkgs.callPackage (import ../../packages/makedumpfile/default.nix) { };
  crash = pkgs.callPackage ../../packages/crash/default.nix { };

  kernelParams = concatStringsSep " " cfg.kernelParams;

  kernelPackage = config.system.build.kernel;
  kernelDebugOutput =
    if builtins.hasAttr "dev" kernelPackage then kernelPackage.dev else kernelPackage;

  crashDebug = pkgs.runCommand "vpsadminos-crash-debug" { preferLocalBuild = true; } ''
    mkdir -p "$out"

    cp ${kernelPackage}/System.map "$out/System.map"
    ${pkgs.gzip}/bin/gzip -n -c ${kernelDebugOutput}/vmlinux > "$out/vmlinux.gz"
    ${pkgs.coreutils}/bin/sha256sum ${kernelDebugOutput}/vmlinux | awk '{print $1}' > "$out/vmlinux.sha256"
  '';

  # Ensure that root= is present, as without this the kernel refuses to boot
  # for some reason.
  filteredParams =
    let
      filtered = filter (param: !(hasPrefix "crashkernel=" param)) config.boot.kernelParams;
      hasRoot = any (param: hasPrefix "root=" param) filtered;
    in
    if hasRoot then filtered else filtered ++ [ "root=none" ];
in
{
  options = {
    boot = {
      crashDump = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            If enabled, NixOS will set up a kernel that will
            boot on crash, and leave the user in systemd rescue
            to be able to save the crashed kernel dump at
            /proc/vmcore.
            It also activates the NMI watchdog.
          '';
        };
        reservedMemory = mkOption {
          default = "2048M";
          type = types.str;
          description = ''
            The amount of memory reserved for the crashdump kernel.
            If you choose a too high value, dmesg will mention
            "crashkernel reservation failed".
          '';
        };
        kernelParams = mkOption {
          type = types.listOf types.str;
          default = [
            # Crash kernels on multi-socket hosts can boot with most reserved
            # memory exposed on a non-boot NUMA node. NFSv4 then may fail to
            # create its callback service thread with ENOMEM even though
            # global free memory is plentiful. Use one allocation domain in
            # the crash kernel, where preserving NUMA locality is irrelevant.
            "numa=off"
            "1"
            "boot.shell_on_fail"
            "loglevel=8"
          ]
          ++ optional (
            config.boot.qemu.enable && config.networking.static.enable
          ) "ip=10.0.2.15:10.0.2.3:10.0.2.2:255.255.255.0:eth0";
          description = ''
            parameters that will be passed to the kernel kexec-ed on crash.
          '';
        };
        commands = mkOption {
          type = types.lines;
          default = "";
          description = ''
            Shell commands to be executed within stage-1 while in crashdump
          '';
        };
        inspect.enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            If enabled, include crash(8) helpers in the crash initrd and attach
            the exact debug payload of the booted kernel to the panic initrd at
            kexec load time.

            This is intentionally optional. When disabled, the crash initrd
            remains as small as before and only contains the tools required for
            the existing makedumpfile-based workflow.
          '';
        };
        consoleSerial = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Enable the serial console.
            '';
          };
          port = mkOption {
            type = types.str;
            default = "ttyS0";
            description = ''
              Specify the serial port for debug output.
            '';
          };
          baudRate = mkOption {
            type = types.int;
            default = 115200;
            description = ''
              Specify the baud rate of the serial port.
            '';
          };
        };
        consoleVGA = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Enable the VGA console.
            '';
          };
          reset = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Attempt to reset a standard VGA device.
            '';
          };
        };
      };
    };
  };

  config = mkIf cfg.enable {
    system.build = {
      crashInitialRamdisk = config.system.build.initialRamdisk;
    }
    // optionalAttrs cfg.inspect.enable {
      crashDebug = crashDebug;
    };

    system.systemBuilderCommands = ''
      ln -s ${config.system.build.crashInitialRamdisk}/initrd $out/crash-initrd
      ${optionalString cfg.inspect.enable "ln -s ${config.system.build.crashDebug} $out/crash-debug"}
    '';

    boot = {
      initrd = {
        extraUtilsCommands = ''
          copy_bin_and_libs ${makedumpfile}/bin/makedumpfile

          # makedumpfile needs libgcc_s.so.1 at runtime, although it doesn't
          # declare it as a dependency.
          cp ${pkgs.libgcc}/lib/libgcc_s.so* $out/lib

          ${optionalString cfg.inspect.enable ''
            copy_bin_and_libs ${crash}/bin/crash

            cat <<'EOF_CRASH_VMCORE' > $out/bin/crash-vmcore
            #!/bin/sh
            set -eu

            vmlinux=''${CRASH_VMLINUX:-/.crash/vmlinux.gz}
            export TERMINFO=''${TERMINFO:-/share/terminfo}
            export TERM=''${TERM:-linux}

            if [ ! -e "$vmlinux" ] ; then
              echo "crash-vmcore: missing $vmlinux" >&2
              exit 1
            fi

            if [ ! -e /proc/vmcore ] ; then
              echo "crash-vmcore: /proc/vmcore is missing" >&2
              exit 1
            fi

            mkdir -p /tmp /var/tmp

            exec crash --no_scroll -f "$@" "$vmlinux" /proc/vmcore
            EOF_CRASH_VMCORE
            chmod +x $out/bin/crash-vmcore

            mkdir -p $out/share/terminfo
            for term in linux xterm xterm-256color screen screen-256color tmux tmux-256color vt100 ; do
              subdir=$(printf '%s' "$term" | cut -c1)
              if [ -e ${pkgs.ncurses}/share/terminfo/$subdir/$term ] ; then
                mkdir -p $out/share/terminfo/$subdir
                cp ${pkgs.ncurses}/share/terminfo/$subdir/$term $out/share/terminfo/$subdir/
              fi
            done

            cat <<'EOF_CRASH_COLLECT' > $out/bin/crash-collect
            #!/bin/sh
            set -u

            outdir=''${1:-/tmp/crash-inspect}
            tmpdir=$(mktemp -d /tmp/crash-collect.XXXXXX)
            status=0
            trap 'rm -rf "$tmpdir"' EXIT

            mkdir -p "$outdir"
            : > "$outdir/status"

            cat > "$outdir/README" <<'EOF_COLLECT_README'
            Files written by crash-collect:
              manifest                        basic metadata about the collected vmcore
              status                          exit status of each crash command
              sys.txt                         sys, sys -t, kmem -i
              log.txt                         log -m
              ps.txt                          ps
              ps-summary.txt                  ps -S
              ps-last-run.txt                 ps -m
              ps-active.txt                   ps -A
              bt-panic.txt                    bt -p
              bt-active.txt                   bt -a
              bt-active-nonidle.txt           bt -a -n idle
              bt-sleeping-interruptible.txt   foreach IN bt
              bt-sleeping-uninterruptible.txt foreach UN bt
            EOF_COLLECT_README

            cat > "$outdir/manifest" <<EOF_COLLECT_MANIFEST
            vmlinux=''${CRASH_VMLINUX:-/.crash/vmlinux.gz}
            vmcore=/proc/vmcore
            crash_binary=$(readlink -f "$(command -v crash)")
            EOF_COLLECT_MANIFEST

            run_crash() {
              local name rc cmdfile
              name="$1"
              cmdfile="$tmpdir/$1.cmd"
              cat > "$cmdfile"
              echo "crash-collect: $name"
              if crash-vmcore -i "$cmdfile" > "$outdir/$name" 2>&1 ; then
                rc=0
              else
                rc=$?
                status=1
              fi
              echo "$name $rc" >> "$outdir/status"
              return 0
            }

            run_crash sys.txt <<'EOF_CRASH_SYS'
            sys
            sys -t
            kmem -i
            quit
            EOF_CRASH_SYS

            run_crash log.txt <<'EOF_CRASH_LOG'
            log -m
            quit
            EOF_CRASH_LOG

            run_crash ps.txt <<'EOF_CRASH_PS'
            ps
            quit
            EOF_CRASH_PS

            run_crash ps-summary.txt <<'EOF_CRASH_PS_SUMMARY'
            ps -S
            quit
            EOF_CRASH_PS_SUMMARY

            run_crash ps-last-run.txt <<'EOF_CRASH_PS_LAST_RUN'
            ps -m
            quit
            EOF_CRASH_PS_LAST_RUN

            run_crash ps-active.txt <<'EOF_CRASH_PS_ACTIVE'
            ps -A
            quit
            EOF_CRASH_PS_ACTIVE

            run_crash bt-panic.txt <<'EOF_CRASH_BT_PANIC'
            bt -p
            quit
            EOF_CRASH_BT_PANIC

            run_crash bt-active.txt <<'EOF_CRASH_BT_ACTIVE'
            bt -a
            quit
            EOF_CRASH_BT_ACTIVE

            run_crash bt-active-nonidle.txt <<'EOF_CRASH_BT_ACTIVE_NONIDLE'
            bt -a -n idle
            quit
            EOF_CRASH_BT_ACTIVE_NONIDLE

            run_crash bt-sleeping-interruptible.txt <<'EOF_CRASH_BT_SLEEPING_INTERRUPTIBLE'
            foreach IN bt
            quit
            EOF_CRASH_BT_SLEEPING_INTERRUPTIBLE

            run_crash bt-sleeping-uninterruptible.txt <<'EOF_CRASH_BT_SLEEPING_UNINTERRUPTIBLE'
            foreach UN bt
            quit
            EOF_CRASH_BT_SLEEPING_UNINTERRUPTIBLE

            exit $status
            EOF_CRASH_COLLECT
            chmod +x $out/bin/crash-collect
          ''}
        '';
        preLVMCommands = ''
          if grep this_is_a_crash_kernel /proc/cmdline; then
            echo "This is a crash kernel"
            ${cfg.commands}
            exit 1
          fi
        '';
      };
      kernelParams = [
        "crashkernel=${cfg.reservedMemory}"
        "softlockup_panic=1"
      ];
    };

    runit.services.crashdump = {
      run = ''
        crashdumpParams="${concatStringsSep " " filteredParams} init=$(readlink -f /run/current-system/init) reset_devices irqpoll modprobe.blacklist=zfs,spl this_is_a_crash_kernel ${kernelParams}"

        httpRoot="$(sed -n 's/.*httproot=\([^[:space:]]*\).*/\1/p' /proc/cmdline)"

        if [ -n "$httpRoot" ] ; then
          crashdumpParams="httproot=$httpRoot $crashdumpParams"
        fi

        kernel=$(realpath /run/current-system/kernel)
        baseInitrd=$(realpath /run/current-system/crash-initrd)
        initrd=$baseInitrd

        ${optionalString cfg.inspect.enable ''
          bootedDebug=/run/booted-system/crash-debug
          crashdumpWorkdir=/run/crashdump
          overlayRoot=$crashdumpWorkdir/overlay
          overlayCpio=$crashdumpWorkdir/crash-debug.cpio
          overlayInitrd=$crashdumpWorkdir/crash-debug.cpio.gz

          rm -rf "$crashdumpWorkdir"

          if [ -d "$bootedDebug" ] ; then
            mkdir -p "$overlayRoot/.crash"
            cp "$bootedDebug/vmlinux.gz" "$overlayRoot/.crash/vmlinux.gz"
            cp "$bootedDebug/System.map" "$overlayRoot/.crash/System.map"
            cp "$bootedDebug/vmlinux.sha256" "$overlayRoot/.crash/vmlinux.sha256"

            {
              printf 'booted_debug=%s\n' "$bootedDebug"
              printf 'booted_vmlinux_sha256=%s\n' "$(cat "$bootedDebug/vmlinux.sha256")"
              printf 'kernel=%s\n' "$kernel"
              printf 'base_initrd=%s\n' "$baseInitrd"
            } > "$overlayRoot/.crash/manifest"

            (
              cd "$overlayRoot"
              find . | ${pkgs.cpio}/bin/cpio -o -H newc --quiet > "$overlayCpio"
            )

            ${pkgs.gzip}/bin/gzip -n -c "$overlayCpio" > "$overlayInitrd"
            initrd=$crashdumpWorkdir/panic-initrd
            cat "$baseInitrd" "$overlayInitrd" > "$initrd"
          else
            echo "Warning: crash inspection requested, but $bootedDebug is missing; using base initrd"
          fi
        ''}

        echo "Loading crashdump kernel"
        echo "kernel=$kernel"
        echo "initrd=$initrd"
        echo "params=$crashdumpParams"

        ${pkgs.kexec-tools}/sbin/kexec \
          --load-panic $kernel \
          --initrd=$initrd \
          ${optionalString cfg.consoleVGA.reset "--reset-vga"} \
          ${optionalString cfg.consoleVGA.enable "--console-vga"} \
          ${optionalString cfg.consoleSerial.enable "--console-serial --serial=${cfg.consoleSerial.port} --serial-baud=${toString cfg.consoleSerial.baudRate}"} \
          --command-line="$crashdumpParams"

        rc=$?

        if [ $rc != 0 ] ; then
          echo "Unable to load crashdump kernel, kexec failed with $rc"
        fi
      '';
      oneShot = true;
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
