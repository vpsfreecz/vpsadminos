{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osctl.rtnlWatchdog;
  s = cfg.settings;
  integer =
    min: max: default: description:
    lib.mkOption {
      type = lib.types.ints.between min max;
      inherit default description;
    };
  arguments = lib.escapeShellArgs [
    "--state-file"
    "/run/rtnl-watchdog.json"
    "--lock-file"
    "/run/rtnl-watchdog.lock"
    "--metrics-file"
    s.metricsFile
    "--interval-ms"
    (toString s.intervalMs)
    "--threshold-ms"
    (toString s.thresholdMs)
    "--tick-ms"
    (toString s.tickMs)
    "--error-backoff-ms"
    (toString s.errorBackoffMs)
  ];
in
{
  options.osctl.rtnlWatchdog = {
    enable = lib.mkEnableOption "active global RTNL-path responsiveness watchdog";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.rtnl-watchdog;
      defaultText = lib.literalExpression "pkgs.rtnl-watchdog";
      description = "Observer and private probe helper built and installed together.";
    };
    settings = {
      intervalMs = integer 100 60000 1000 "Minimum spacing after probe completion in milliseconds.";
      thresholdMs =
        integer 100 60000 1000
          "Announced pending age considered distressed, in milliseconds.";
      tickMs = integer 50 1000 250 "Observer heartbeat interval in milliseconds.";
      errorBackoffMs =
        integer 100 3600000 5000
          "Completed error or reaped-helper backoff in milliseconds.";
      metricsFile = lib.mkOption {
        type = lib.types.strMatching "/[^\n]+";
        default = "/run/metrics/rtnl-watchdog.prom";
        description = "Absolute Prometheus textfile path exclusively owned by the watchdog.";
      };
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = s.thresholdMs >= s.tickMs;
        message = "osctl.rtnlWatchdog thresholdMs must be at least tickMs.";
      }
    ];
    environment.systemPackages = [ cfg.package ];
    runit.services.rtnl-watchdog = {
      # The default control-group finish would signal an unresolved child.
      killMode = "process";
      run = ''
        ${pkgs.coreutils}/bin/mkdir -p -- /run ${lib.escapeShellArg (builtins.dirOf s.metricsFile)}
        exec 2>&1
        exec ${cfg.package}/bin/rtnl-watchdog ${arguments}
      '';
      # No finish cleanup: never unlink the inherited lifetime lock. The native
      # observer removes only its own outputs after its writer has exited.
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
