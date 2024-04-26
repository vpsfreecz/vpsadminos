{ config, lib, pkgs, options }:
let
  inherit (lib) concatMapStringsSep concatStringsSep;

  cfg = config.services.prometheus.exporters.osctl;
in {
  user = "root";
  group = "root";
  port = 9101;
  serviceRun = ''
    export PATH="${pkgs.osctl-exporter}/env/bin:$PATH"

    execExporter thin \
      -a ${cfg.listenAddress} \
      -p ${toString cfg.port} \
      -R ${pkgs.osctl-exporter}/config.ru \
      -e production \
      ${concatStringsSep " \\\n  " cfg.extraFlags} \
      start
  '';
}
