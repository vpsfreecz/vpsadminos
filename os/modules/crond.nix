{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  cfg = config.services.cron;
in
{
  ###### interface

  options = {
  };

  ###### implementation

  config = mkMerge [
    (mkIf cfg.enable {
      runit.services.crond.run = ''
          exec ${pkgs.cron}/bin/cron -n # run in foreground
      '';
    })
  ];
}
