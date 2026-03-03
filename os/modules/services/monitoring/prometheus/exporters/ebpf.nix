{
  config,
  lib,
  pkgs,
  options,
}:

with lib;

let
  cfg = config.services.prometheus.exporters.ebpf;
in
{
  user = "root";
  group = "root";
  port = 9435;

  extraOpts = {
    package = mkOption {
      type = types.package;
      default = pkgs.prometheus-ebpf-exporter;
      defaultText = literalExpression "pkgs.prometheus-ebpf-exporter";
      description = lib.mdDoc ''
        Package with `ebpf_exporter` binary and compiled example programs.
      '';
    };

    configDir = mkOption {
      type = types.path;
      default = "${cfg.package}/examples";
      defaultText = literalExpression ''"${cfg.package}/examples"'';
      description = lib.mdDoc ''
        Path to directory with `<name>.bpf.o` and `<name>.yaml` files.
      '';
    };

    names = mkOption {
      type = types.listOf types.str;
      default = [ "timers" ];
      example = [ "rtnl_lock-latency" ];
      description = lib.mdDoc ''
        Names of eBPF configs to load from `configDir`.
      '';
    };
  };

  serviceRun = ''
    execExporter ${cfg.package}/bin/ebpf_exporter \
      --config.dir=${cfg.configDir} \
      --config.names=${concatStringsSep "," cfg.names} \
      --web.listen-address ${cfg.listenAddress}:${toString cfg.port} \
      ${concatStringsSep " \\\n  " cfg.extraFlags}
  '';
}
