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

            profile=essential

            case "''${1:-}" in
              --full)
                profile=full
                shift
                ;;
              -h|--help)
                echo "usage: crash-collect [--full] [OUTDIR]"
                exit 0
                ;;
              -*)
                echo "crash-collect: unknown option: $1" >&2
                exit 2
                ;;
            esac

            if [ "$#" -gt 1 ] ; then
              echo "usage: crash-collect [--full] [OUTDIR]" >&2
              exit 2
            fi

            outdir=''${1:-/tmp/crash-inspect}
            tmpdir=$(mktemp -d /tmp/crash-collect.XXXXXX) || exit 1
            overall_status=0
            trap 'rm -rf "$tmpdir"' EXIT

            mkdir -p "$outdir" || exit 1
            outdir=$(cd "$outdir" && pwd -P) || exit 1

            cat > "$outdir/README" <<'EOF_COLLECT_README'
            Usage: crash-collect [--full] [OUTDIR]

            The default essential profile prioritizes evidence needed to
            diagnose the panic and active CPUs. The --full profile appends
            expensive whole-task-table reports after essential collection.

            Files written by both profiles:
              manifest                        basic metadata about the collected vmcore
              status                          collection and output status
              timings                         start, end and duration of each report
              session.log                     crash(8) initialization and command log
              sys.txt                         sys, sys -t, kmem -i
              log.txt                         log -m
              ps-summary.txt                  ps -S
              tasks.txt                       lightweight task identity and state inventory
              bt-panic.txt                    bt -p
              bt-active.txt                   bt -a -n idle
              bt-sleeping-uninterruptible.txt foreach UN bt

            Additional files written by --full:
              ps.txt                          ps
              ps-last-run.txt                 ps -m
              ps-active.txt                   ps -A
              bt-sleeping-interruptible.txt   foreach IN bt
            EOF_COLLECT_README

            cat > "$outdir/manifest" <<EOF_COLLECT_MANIFEST
            vmlinux=''${CRASH_VMLINUX:-/.crash/vmlinux.gz}
            vmcore=/proc/vmcore
            crash_binary=$(readlink -f "$(command -v crash)")
            profile=$profile
            EOF_COLLECT_MANIFEST

            cmdfile="$tmpdir/collect.cmd"
            cat > "$cmdfile" <<'EOF_CRASH_ESSENTIAL'
            !date +%s > .sys.txt.start
            sys > sys.txt
            sys -t >> sys.txt
            kmem -i >> sys.txt
            !date +%s > .sys.txt.end

            !date +%s > .log.txt.start
            log -m > log.txt
            !date +%s > .log.txt.end

            !date +%s > .bt-panic.txt.start
            bt -p > bt-panic.txt
            !date +%s > .bt-panic.txt.end

            !date +%s > .bt-active.txt.start
            bt -a -n idle > bt-active.txt
            !date +%s > .bt-active.txt.end

            !date +%s > .bt-sleeping-uninterruptible.txt.start
            foreach UN bt > bt-sleeping-uninterruptible.txt
            !date +%s > .bt-sleeping-uninterruptible.txt.end

            !date +%s > .ps-summary.txt.start
            ps -S > ps-summary.txt
            !date +%s > .ps-summary.txt.end

            !date +%s > .tasks.txt.start
            foreach task -R __state,real_parent > tasks.txt
            !date +%s > .tasks.txt.end
            EOF_CRASH_ESSENTIAL

            reports="sys.txt log.txt bt-panic.txt bt-active.txt bt-sleeping-uninterruptible.txt ps-summary.txt tasks.txt"

            if [ "$profile" = full ] ; then
              cat >> "$cmdfile" <<'EOF_CRASH_FULL'

            !date +%s > .ps.txt.start
            ps > ps.txt
            !date +%s > .ps.txt.end

            !date +%s > .ps-last-run.txt.start
            ps -m > ps-last-run.txt
            !date +%s > .ps-last-run.txt.end

            !date +%s > .ps-active.txt.start
            ps -A > ps-active.txt
            !date +%s > .ps-active.txt.end

            !date +%s > .bt-sleeping-interruptible.txt.start
            foreach IN bt > bt-sleeping-interruptible.txt
            !date +%s > .bt-sleeping-interruptible.txt.end
            EOF_CRASH_FULL

              reports="$reports ps.txt ps-last-run.txt ps-active.txt bt-sleeping-interruptible.txt"
            fi

            echo quit >> "$cmdfile"

            echo "crash-collect: profile $profile"
            session_start=$(date +%s)
            if (cd "$outdir" && crash-vmcore -i "$cmdfile") > "$outdir/session.log" 2>&1 ; then
              session_rc=0
            else
              session_rc=$?
              overall_status=1
            fi
            session_end=$(date +%s)

            : > "$outdir/status"
            echo "session $session_rc" >> "$outdir/status"

            : > "$outdir/timings"
            echo "session start=$session_start end=$session_end duration=$((session_end - session_start))s" \
              >> "$outdir/timings"

            for name in $reports ; do
              if [ -s "$outdir/$name" ] ; then
                echo "$name 0" >> "$outdir/status"
              else
                echo "$name 1" >> "$outdir/status"
                overall_status=1
              fi

              if [ -s "$outdir/.$name.start" ] && [ -s "$outdir/.$name.end" ] ; then
                start=$(cat "$outdir/.$name.start")
                end=$(cat "$outdir/.$name.end")
                echo "$name start=$start end=$end duration=$((end - start))s" \
                  >> "$outdir/timings"
              else
                echo "$name timing=incomplete" >> "$outdir/timings"
                overall_status=1
              fi

              rm -f "$outdir/.$name.start" "$outdir/.$name.end"
            done

            exit $overall_status
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
