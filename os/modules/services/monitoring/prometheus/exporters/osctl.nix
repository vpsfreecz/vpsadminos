{ config, lib, pkgs, options }:
let
  inherit (lib) concatMapStringsSep concatStringsSep;

  cfg = config.services.prometheus.exporters.osctl;

  pumaConfig = pkgs.writeText "puma.rb" ''
    bind 'tcp://${cfg.listenAddress}:${toString cfg.port}'
    rackup '${pkgs.osctl-exporter}/config.ru'
    environment 'production'
    tag 'osctl-exporter'
   '';
in {
  user = "root";
  group = "root";
  port = 9101;
  serviceRun = ''
    export PATH="${pkgs.osctl-exporter}/env/bin:$PATH"

    execExporter puma -C ${pumaConfig} \
      ${concatStringsSep " \\\n  " cfg.extraFlags}
  '';
}
