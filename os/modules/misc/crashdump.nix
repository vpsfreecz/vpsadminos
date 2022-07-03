{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.boot.crashDump;

  kernelParams = concatStringsSep " " cfg.kernelParams;

  makedumpfile = pkgs.callPackage (import ../../packages/makedumpfile/default.nix) {};

  filteredParams = builtins.filter (param: !(strings.hasPrefix "crashkernel=" param)) config.boot.kernelParams;

in
###### interface
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
          '';
        };
        reservedMemory = mkOption {
          default = "512M";
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
        execAfterDump = mkOption {
          type = types.str;
          default = "";
          description = ''
            shell commands to be executed after makedumpfile outputs /dmesg
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

###### implementation

  config = mkIf cfg.enable {
    boot = {
      initrd = {
        extraUtilsCommands = ''
          copy_bin_and_libs ${makedumpfile}/bin/makedumpfile
        '';
        preLVMCommands = ''
          if grep this_is_a_crash_kernel /proc/cmdline; then
            echo This is a crash kernel;
            echo ${makedumpfile.src.rev}
            makedumpfile -D --dump-dmesg /proc/vmcore /dmesg
            ls -lah /dmesg
            ${cfg.execAfterDump}
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
        --command-line="${strings.concatStringsSep " " filteredParams} init=$(readlink -f /run/current-system/init) irqpoll maxcpus=1 this_is_a_crash_kernel ${kernelParams}"
      '';
      kernelParams = [
       "crashkernel=${cfg.reservedMemory}"
       "softlockup_panic=1"
      ];
    };
  };
}
