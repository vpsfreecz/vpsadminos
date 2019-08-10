{ config, lib, pkgs, utils, ... }:
with lib;
let
  cfg = config.osctl.exporter;
in {
  ###### interface

  options = {
    osctl.exporter = {
      enable = mkOption {
        type = types.bool;
        default = config.services.prometheus.exporters.node.enable;
        description = ''
          Enable osctl-exporter.
        '';
      };

      listenAddress = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = ''
          Address to listen on.
        '';
      };

      port = mkOption {
        type = types.int;
        default = 9101;
        description = ''
          Port to listen on.
        '';
      };
    };
  };

  ###### implementation

  config = mkIf cfg.enable {
    runit.services.osctl-exporter = {
      run = ''
        export PATH="${pkgs.osctl-exporter}/env/bin:$PATH"
        exec 2>&1
        waitForOsctld
        exec thin \
          -a ${cfg.listenAddress} \
          -p ${toString cfg.port} \
          -R ${pkgs.osctl-exporter}/config.ru \
          -e production \
          start
      '';
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
