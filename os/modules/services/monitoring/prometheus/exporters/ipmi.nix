{ config, lib, pkgs, options }:

with lib;

let
  cfg = config.services.prometheus.exporters.ipmi;
in {
  user = "root";
  group = "root";
  port = 9290;

  extraOpts = {
    configFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = lib.mdDoc ''
        Path to configuration file.
      '';
    };

    webConfigFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = lib.mdDoc ''
        Path to configuration file that can enable TLS or authentication.
      '';
    };
  };

  serviceRun = with cfg; concatStringsSep " " ([
      "execExporter"
      "${pkgs.prometheus-ipmi-exporter}/bin/ipmi_exporter"
      "--web.listen-address ${listenAddress}:${toString port}"
    ] ++ optionals (cfg.webConfigFile != null) [
      "--web.config.file ${escapeShellArg cfg.webConfigFile}"
    ] ++ optionals (cfg.configFile != null) [
      "--config.file ${escapeShellArg cfg.configFile}"
    ] ++ extraFlags);
}
