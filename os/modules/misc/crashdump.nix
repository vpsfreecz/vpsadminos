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
  crashBuffer = pkgs.callPackage ../../packages/crash-buffer/default.nix { };

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
            copy_bin_and_libs ${crashBuffer}/bin/crash-buffer

            cat <<'EOF_CRASH_VMCORE' > $out/bin/crash-vmcore
            #!/bin/sh
            set -eu

            vmlinux=''${CRASH_VMLINUX:-/.crash/vmlinux.gz}
            crash_binary=''${CRASH_BINARY:-crash}
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

            exec "$crash_binary" --no_scroll -f "$@" "$vmlinux" /proc/vmcore
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
            collector_start_ms=$(awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime)
            status=0
            trap 'rm -rf "$tmpdir"' EXIT

            mkdir -p "$outdir"
            : > "$outdir/status"
            : > "$tmpdir/timings.raw"

            for report in \
              sys.txt \
              log.txt \
              ps.txt \
              ps-summary.txt \
              ps-last-run.txt \
              ps-active.txt \
              bt-panic.txt \
              bt-active.txt \
              bt-active-nonidle.txt \
              bt-sleeping-interruptible.txt \
              bt-sleeping-uninterruptible.txt ; do
              : > "$outdir/$report"
            done

            cat > "$outdir/README" <<'EOF_COLLECT_README'
            Files written by crash-collect:
              manifest                        basic metadata about the collected vmcore
              status                          completion status of each logical report
              timings                         elapsed milliseconds by report and phase
              session.txt                     crash startup and session diagnostics
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

            Report payloads are streamed directly to their destination through one
            bounded 256 KiB writer. Only command, timing and completion marker files
            are held in /tmp. Timings exclude the caller's final filesystem sync.
            EOF_COLLECT_README

            cat > "$outdir/manifest" <<EOF_COLLECT_MANIFEST
            collector_version=2
            crash_sessions=1
            crash_options=--no_kmem_cache
            output_buffer_bytes=262144
            report_storage=direct
            vmlinux=''${CRASH_VMLINUX:-/.crash/vmlinux.gz}
            vmcore=/proc/vmcore
            crash_binary=$(readlink -f "$(command -v crash)")
            session_log=session.txt
            timings=timings
            EOF_COLLECT_MANIFEST

            report_status() {
              local name rc marker
              name="$1"
              shift
              rc=0

              for marker in "$@" ; do
                if [ ! -f "$tmpdir/$marker.complete" ] ; then
                  rc=1
                  break
                fi
              done

              if [ "$rc" != 0 ] ; then
                status=1
              fi

              echo "$name $rc" >> "$outdir/status"
            }

            export CRASH_COLLECT_OUTDIR="$outdir"
            export CRASH_COLLECT_TMPDIR="$tmpdir"
            export CRASH_COLLECT_TIMINGS="$tmpdir/timings.raw"

            cat > "$tmpdir/session.cmd" <<'EOF_CRASH_SESSION'
            sys | crash-buffer --since "$CRASH_COLLECT_SESSION_START_MS" --timing sys.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/sys-1.complete" "$CRASH_COLLECT_OUTDIR/sys.txt"
            sys -t | crash-buffer --append --timing sys.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/sys-2.complete" "$CRASH_COLLECT_OUTDIR/sys.txt"
            kmem -i | crash-buffer --append --timing sys.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/sys-3.complete" "$CRASH_COLLECT_OUTDIR/sys.txt"
            log -m | crash-buffer --timing log.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/log.complete" "$CRASH_COLLECT_OUTDIR/log.txt"
            bt -p | crash-buffer --timing bt-panic.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/bt-panic.complete" "$CRASH_COLLECT_OUTDIR/bt-panic.txt"
            bt -a | crash-buffer --timing bt-active.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/bt-active.complete" "$CRASH_COLLECT_OUTDIR/bt-active.txt"
            bt -a -n idle | crash-buffer --timing bt-active-nonidle.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/bt-active-nonidle.complete" "$CRASH_COLLECT_OUTDIR/bt-active-nonidle.txt"
            foreach UN bt | crash-buffer --timing bt-sleeping-uninterruptible.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/bt-uninterruptible.complete" "$CRASH_COLLECT_OUTDIR/bt-sleeping-uninterruptible.txt"
            ps -S | crash-buffer --timing ps-summary.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/ps-summary.complete" "$CRASH_COLLECT_OUTDIR/ps-summary.txt"
            ps -A | crash-buffer --timing ps-active.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/ps-active.complete" "$CRASH_COLLECT_OUTDIR/ps-active.txt"
            ps | crash-buffer --timing ps.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/ps.complete" "$CRASH_COLLECT_OUTDIR/ps.txt"
            foreach IN bt | crash-buffer --timing bt-sleeping-interruptible.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/bt-interruptible.complete" "$CRASH_COLLECT_OUTDIR/bt-sleeping-interruptible.txt"
            ps -m | crash-buffer --timing ps-last-run.txt "$CRASH_COLLECT_TIMINGS" --complete "$CRASH_COLLECT_TMPDIR/ps-last-run.complete" "$CRASH_COLLECT_OUTDIR/ps-last-run.txt"
            quit
            EOF_CRASH_SESSION

            session_start_ms=$(awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime)
            export CRASH_COLLECT_SESSION_START_MS="$session_start_ms"

            echo "crash-collect: starting crash session"
            if crash-vmcore --no_kmem_cache -i "$tmpdir/session.cmd" \
              > "$outdir/session.txt" 2>&1 ; then
              crash_rc=0
            else
              crash_rc=$?
              status=1
            fi

            session_end_ms=$(awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime)
            echo "session $((session_end_ms - session_start_ms))" \
              >> "$tmpdir/timings.raw"
            echo "crash_exit_status=$crash_rc" >> "$outdir/manifest"

            report_status sys.txt sys-1 sys-2 sys-3
            report_status log.txt log
            report_status ps.txt ps
            report_status ps-summary.txt ps-summary
            report_status ps-last-run.txt ps-last-run
            report_status ps-active.txt ps-active
            report_status bt-panic.txt bt-panic
            report_status bt-active.txt bt-active
            report_status bt-active-nonidle.txt bt-active-nonidle
            report_status bt-sleeping-interruptible.txt bt-interruptible
            report_status bt-sleeping-uninterruptible.txt bt-uninterruptible

            awk '
              !seen[$1]++ { order[++count] = $1 }
              { elapsed[$1] += $2 }
              END {
                for (i = 1; i <= count; i++)
                  print order[i], elapsed[order[i]]
              }
            ' "$tmpdir/timings.raw" > "$outdir/timings"

            collector_end_ms=$(awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime)
            echo "collector $((collector_end_ms - collector_start_ms))" \
              >> "$outdir/timings"

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
      restartTriggers = [
        config.system.build.kernel
        config.system.build.crashInitialRamdisk
        config.system.build.bootStage2
      ];

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
