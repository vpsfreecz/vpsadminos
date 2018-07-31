{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  cfg = config.services.logrotate;
  configFile = pkgs.writeText "logrotate.conf" ''
    ${cfg.defaultConfig}
    ${cfg.extraConfig}
  '';
in
{
  ###### interface

  options = {
    services = {
      logrotate = {
        enable = mkEnableOption "Enable log rotation";

        defaultConfig = mkOption {
          type = types.string;
          default = ''
            /var/log/* {
              daily
              rotate 7
              dateext
              copytruncate
              notifempty
              nocompress
            }
          '';
        };

        extraConfig = mkOption {
          type = types.string;
          default = "";
          example = ''
            /var/log/wtmp {
              monthly
              minsize 1M
              create 0664 root utmp
              rotate 1
            }
          '';
          description = "Additional text to append to logrotate.conf";
        };
      };
    };
  };

  ###### implementation

  config = mkIf cfg.enable {
    services.cron.enable = true;
    services.cron.systemCronJobs = [
      "* * * 05 00  root  exec ${pkgs.logrotate}/sbin/logrotate ${configFile}"
    ];
  };
}
