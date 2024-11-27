{ config, lib, pkgs, ... }:
let
  inherit (lib) any concatStringsSep filter hasPrefix mkIf mkOption optional optionalString types;

  cfg = config.boot.crashDump;

  makedumpfile = pkgs.callPackage (import ../../packages/makedumpfile/default.nix) {};

  kernelParams = concatStringsSep " " cfg.kernelParams;

  # Ensure that root= is present, as without this the kernel refuses to boot
  # for some reason
  filteredParams =
    let
      filtered = filter (param: !(hasPrefix "crashkernel=" param)) config.boot.kernelParams;
      hasRoot = any (param: hasPrefix "root=" param) filtered;
    in if hasRoot then filtered else filtered ++ [ "root=none" ];

in {
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
          default = "1024M";
          type = types.str;
          description = ''
            The amount of memory reserved for the crashdump kernel.
            If you choose a too high value, dmesg will mention
            "crashkernel reservation failed".
          '';
        };
        kernelParams = mkOption {
          type = types.listOf types.str;
          default = [ "1" "boot.shell_on_fail" "loglevel=8" ]
            ++ optional (config.boot.qemu.enable && config.networking.static.enable) "ip=10.0.2.15:10.0.2.3:10.0.2.2:255.255.255.0:eth0";
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
    boot = {
      initrd = {
        extraUtilsCommands = ''
          copy_bin_and_libs ${makedumpfile}/bin/makedumpfile
        '';
        preLVMCommands = ''
          if grep this_is_a_crash_kernel /proc/cmdline; then
            echo "This is a crash kernel"
            ${cfg.commands}
            exit 1
          fi
        '';
      };
      postBootCommands = ''
        echo "loading crashdump kernel...";
        ${pkgs.kexec-tools}/sbin/kexec -p /run/current-system/kernel \
        --initrd=/run/current-system/initrd \
      '' + optionalString cfg.consoleVGA.reset ''
        --reset-vga \
      '' + optionalString cfg.consoleVGA.enable ''
        --console-vga \
      '' + optionalString cfg.consoleSerial.enable ''
        --console-serial \
        --serial=${cfg.consoleSerial.port} --serial-baud=${toString cfg.consoleSerial.baudRate} \
      '' + ''
        --command-line="${concatStringsSep " " filteredParams} init=$(readlink -f /run/current-system/init) reset_devices irqpoll maxcpus=1 modprobe.blacklist=zfs,spl this_is_a_crash_kernel ${kernelParams}"
      '';
      kernelParams = [
       "crashkernel=${cfg.reservedMemory}"
       "softlockup_panic=1"
      ];
    };
  };
}
