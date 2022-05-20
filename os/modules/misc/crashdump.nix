{ config, lib, pkgs, ... }:

with lib;

let
  crashdump = config.boot.crashDump;

  kernelParams = concatStringsSep " " crashdump.kernelParams;

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
            It also activates the NMI watchdog.
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
          default = filteredParams ++ [ "1" "boot.shell_on_fail" "loglevel=8" ];
          description = ''
            Parameters that will be passed to the kernel kexec-ed on crash.
          '';
        };
      };
    };
  };

###### implementation

  config = mkIf crashdump.enable {
    boot = {
      initrd = {
        extraUtilsCommands = ''
          copy_bin_and_libs ${pkgs.openssh}/bin/ssh
          copy_bin_and_libs ${pkgs.openssh}/bin/scp
          copy_bin_and_libs ${makedumpfile}/bin/makedumpfile
        '';
        preLVMCommands = ''
          if grep this_is_a_crash_kernel /proc/cmdline; then
  		echo This is a crash kernel;
  		exit 1
  	fi
        '';
      };
      postBootCommands = ''
        echo "loading crashdump kernel...";
        ${pkgs.kexec-tools}/sbin/kexec -p /run/current-system/kernel \
        --initrd=/run/current-system/initrd \
        --command-line="init=$(readlink -f /run/current-system/init) irqpoll maxcpus=1 reset_devices this_is_a_crash_kernel ${kernelParams}"
      '';
      kernelParams = [
       "crashkernel=${crashdump.reservedMemory}"
       "softlockup_panic=1"
      ];
    };
  };
}
