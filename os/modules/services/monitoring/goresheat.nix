{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.goresheat;
in
{
  ###### interface

  options = {

    services.goresheat = {

      enable = mkOption {
        default = false;
        type = types.bool;
        description = ''

        '';
      };
      host = mkOption {
        default = "0.0.0.0";
        type = types.str;
        description = ''
          The host on which goresheat will listen for incoming connections.
        '';
      };
      port = mkOption {
        default = 8080;
        type = types.int;
        description = ''
          The port on which goresheat will listen for incoming connections.
        '';
      };
      url = mkOption {
        default = null;
        type = types.nullOr types.str;
        description = ''
          Custom URL on which goresheat is accessible, use e.g. when it is behind a proxy
        '';
      };
      rectSize = mkOption {
        default = 9;
        type = types.int;
        description = ''
          The size of the rectangles that will be drawn on the screen.
        '';
      };
      interval = mkOption {
        default = "100ms";
        type = types.str;
        description = ''
          The interval at which new data will be read.
        '';
      };
    };
  };

  ###### implementation

  config = mkIf cfg.enable {
    runit.services.goresheat = {
      run = ''
        mkdir -p /run/goresheat
        exec ${pkgs.goresheat}/bin/goresheat -host ${cfg.host} -port ${toString cfg.port} ${optionalString (!isNull cfg.url) "-url ${cfg.url}"} -rectsize ${toString cfg.rectSize} -interval ${cfg.interval}
      '';
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
