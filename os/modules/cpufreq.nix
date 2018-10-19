{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

{
  ###### interface

  options = {
    powerManagement.cpuFreqGovernor = mkOption {
      type = types.string;
      description = "CPU frequency scaling governor to use";
      default = "performance";
      example = "ondemand";
    };
  };

  ###### implementation

  config = {
    runit.services = {
      cpufreq.run = ''
        sv check eudev-trigger >/dev/null || exit 1
        test -d /sys/devices/system/cpu/cpu0/cpufreq && \
          echo ${config.powerManagement.cpuFreqGovernor} > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
        sv once .
      '';
    };
  };
}
