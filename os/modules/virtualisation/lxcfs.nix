{ config, lib, pkgs, utils, ... }:
with utils;
with lib;
let
  cfg = config.services.lxcfs;
in {
  ###### interface

  options = {
    services.lxcfs = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable system-wide LXCFS instance
        '';
      };
    };
  };

  ###### implementation

  config = {
    runit.services.lxcfs = mkIf cfg.enable {
      run = ''
        mkdir -p /var/lib/lxcfs
        umount /var/lib/lxcfs 2> /dev/null
        exec ${pkgs.lxcfs}/bin/lxcfs --enable-loadavg --enable-cfs /var/lib/lxcfs
      '';

      onChange = "reload";
      reloadMethod = "1";

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
