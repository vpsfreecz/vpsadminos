{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  cfg = config.services.logrotate;

  fileNames = map (v: "\"${v}\"");

  genLogFiles = logFiles: concatStringsSep "\n\n" (map (log: ''
    ${concatStringsSep "\n" (fileNames log.files)}
    {
      ${log.config}
    }
  '') logFiles);

  configFile = pkgs.writeText "logrotate.conf" ''
    ${genLogFiles cfg.logFiles}
    ${cfg.extraConfig}
  '';

  mkLogFiles = {
    options = {
      files = mkOption {
        type = types.listOf types.str;
        example = [ "/var/log/messages" "/var/log/*.log" ];
        description = "Files to rotate";
      };

      config = mkOption {
        type = types.str;
        example = ''
          daily
          rotate 7
          dateext
          copytruncate
          notifempty
          nocompress
        '';
        description = "logrotate configuration";
      };
    };
  };
in
{
  ###### interface

  options = {
    services = {
      logrotate = {
        enable = mkEnableOption "Enable log rotation";

        logFiles = mkOption {
          type = types.listOf (types.submodule mkLogFiles);
          default = [];
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
      "*/15 * * * *  root  exec ${pkgs.logrotate}/sbin/logrotate ${configFile} 2> /dev/null"
    ];
  };
}
