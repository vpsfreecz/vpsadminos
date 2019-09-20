{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

{
  ###### interface

  options = {
    powerManagement.cpuFreqGovernor = mkOption {
      type = types.str;
      description = "CPU frequency scaling governor to use";
      default = "performance";
      example = "ondemand";
    };
  };

  ###### implementation

  config = {
    runit.services = {
      cpufreq = {
        run = ''
          ensureServiceStarted eudev-trigger
          test -d /sys/devices/system/cpu/cpu0/cpufreq && \
            ${pkgs.cpufrequtils}/bin/cpufreq-set --governor ${config.powerManagement.cpuFreqGovernor}
        '';
        oneShot = true;
      };
    };
  };
}
