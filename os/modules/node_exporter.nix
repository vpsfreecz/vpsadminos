{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  cfg = config.services.node_exporter;
in
{
  ###### interface

  options = {
    services.node_exporter = {
      enable = mkEnableOption "Enable node_exporter service";
      enabledCollectors = mkOption {
        type = types.listOf types.string;
        default = [ "runit" "nfs" "textfile" ];
        example = ''[ "nfs" ]'';
        description = ''
          Collectors to enable. The collectors listed here are enabled in addition to the default ones.
        '';
      };
      disabledCollectors = mkOption {
        type = types.listOf types.str;
        default = [ "systemd" ];
        example = ''[ "timex" ]'';
        description = ''
          Collectors to disable which are enabled by default.
        '';
      };
      port = mkOption {
        type = types.int;
        default = 9100;
        description = ''
          Port to listen on.
        '';
      };
      listenAddress = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = ''
          Address to listen on.
        '';
      };
      extraFlags = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Extra commandline options to pass to node_exporter.
        '';
      };
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf cfg.enable {
      runit.services.node_exporter.run = ''
        mkdir /run/metrics

        exec ${pkgs.prometheus-node-exporter}/bin/node_exporter \
          ${concatMapStringsSep " " (x: "--collector." + x) cfg.enabledCollectors} \
          ${concatMapStringsSep " " (x: "--no-collector." + x) cfg.disabledCollectors} \
          --web.listen-address ${cfg.listenAddress}:${toString cfg.port} \
          --collector.runit.servicedir=/service \
          --collector.textfile.directory=/run/metrics \
          ${concatStringsSep " \\\n  " cfg.extraFlags} &>/dev/null
      '';

      services.cron.systemCronJobs = [
        "* * * * *  root  exec ${pkgs.machine-check}/bin/machine-check"
      ];
    })
  ];
}
