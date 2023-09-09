{ config, lib, pkgs, options }:

with lib;

let
  cfg = config.services.prometheus.exporters.node;
  enabledCollectors = filter (c: !(elem c cfg.disabledCollectors)) cfg.enabledCollectors;
  textfileDirectory = "/run/metrics";
in {
  user = "root";
  group = "root";
  port = 9100;
  extraOpts = {
    enabledCollectors = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "systemd" ];
      description = lib.mdDoc ''
        Collectors to enable. The collectors listed here are enabled in addition to the default ones.
      '';
    };
    disabledCollectors = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "timex" ];
      description = lib.mdDoc ''
        Collectors to disable which are enabled by default.
      '';
    };
  };
  serviceRun = ''
    mkdir -p ${textfileDirectory}

    execExporter ${pkgs.prometheus-node-exporter}/bin/node_exporter \
      ${concatMapStringsSep " " (x: "--collector." + x) enabledCollectors} \
      ${concatMapStringsSep " " (x: "--no-collector." + x) cfg.disabledCollectors} \
      --web.listen-address ${cfg.listenAddress}:${toString cfg.port} \
      --collector.runit.servicedir=/service \
      ${concatStringsSep " \\\n  " cfg.extraFlags}
  '';
}
