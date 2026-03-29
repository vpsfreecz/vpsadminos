{
  config,
  lib,
  pkgs,
  options,
}:
let
  inherit (lib)
    concatMapStringsSep
    concatStringsSep
    escapeShellArg
    optionalString
    ;

  cfg = config.services.prometheus.exporters.osctl;
  rubyCrashReportTemplate = config.system.vpsadminos.rubyCrashReportTemplate;

  pumaConfig = pkgs.writeText "puma.rb" ''
    bind 'tcp://${cfg.listenAddress}:${toString cfg.port}'
    rackup '${pkgs.osctl-exporter}/config.ru'
    environment 'production'
    tag 'osctl-exporter'
  '';
in
{
  user = "root";
  group = "root";
  port = 9101;
  serviceRun = ''
    ${optionalString (!isNull rubyCrashReportTemplate) ''
      export RUBY_CRASH_REPORT=${escapeShellArg rubyCrashReportTemplate}
    ''}

    export PATH="${pkgs.osctl-exporter}/env/bin:$PATH"

    execExporter puma -C ${pumaConfig} \
      ${concatStringsSep " \\\n  " cfg.extraFlags}
  '';
}
