{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    escapeShellArg
    mkEnableOption
    mkIf
    mkOption
    optionalString
    types
    ;

  cfg = config.osctl.oomd;
  rubyCrashReportTemplate = config.system.vpsadminos.rubyCrashReportTemplate;

  settingsFormat = pkgs.formats.json { };

  raw = cfg.settings;
  # Null option defaults preserve whether legacy interval/seconds were explicit.
  # The CLI is the single legacy conversion boundary and emits its warning.
  effective = lib.filterAttrs (
    name: value:
    !(builtins.elem name [
      "interval"
      "restart_after_seconds"
      "stop_after_seconds"
    ])
    || value != null
  ) raw;
  configurationJson = settingsFormat.generate "osctl-oomd-config.json" effective;
in
{
  options = {
    osctl.oomd = {
      enable = mkEnableOption "Enable osctl-oomd";

      settings = mkOption {
        type = types.submodule {
          freeformType = settingsFormat.type;
          options = {
            interval = mkOption {
              type = types.nullOr types.ints.positive;
              default = null;
              description = "Top sampling interval in seconds; defaults to 5 when omitted.";
            };
            load_enable = mkOption {
              type = types.bool;
              default = true;
              description = "Enable the median load gate.";
            };
            load_multiplier = mkOption {
              type = types.addCheck types.number (n: n > 0);
              default = 2.0;
              description = "Multiplier of historical median load.";
            };
            restart_after_seconds = mkOption {
              type = types.nullOr types.ints.positive;
              default = null;
              description = "Shared qualified restart seconds (90 unless migrating legacy hits).";
            };
            stop_after_seconds = mkOption {
              type = types.nullOr types.ints.positive;
              default = null;
              description = "Qualified load-gated stop seconds (600 unless migrating legacy hits).";
            };
            restart_unknown_expiry_seconds = mkOption {
              type = types.ints.positive;
              default = 30;
              description = "Expiry of restart evidence without usable target observations.";
            };
            rtnl_watchdog = {
              enable = mkEnableOption "RTNL watchdog activation of the existing OOM policy";
              state_file = mkOption {
                type = types.strMatching "/.*";
                default = "/run/rtnl-watchdog.json";
                description = "Root-owned watchdog schema 1 state file.";
              };
              max_age_seconds = mkOption {
                type = types.ints.positive;
                default = 1;
                description = "Maximum watchdog frame age in seconds.";
              };
              latency_threshold_ms = mkOption {
                type = types.ints.between 1 60000;
                default = 1000;
                description = "Strict producer slow-response cutoff, in milliseconds.";
              };
              sustain_seconds = mkOption {
                type = types.ints.positive;
                default = 30;
                description = "Completed consecutive slow-run span required for activation.";
              };
              pending_seconds = mkOption {
                type = types.ints.positive;
                default = 30;
                description = "Continuously covered announced pending probe age required for activation.";
              };
              observation_max_age_seconds = mkOption {
                type = types.ints.positive;
                default = 5;
                description = "Maximum current sweep duration and dispatch sample age.";
              };
              action_workers = mkOption {
                type = types.ints.between 1 2;
                default = 2;
                description = "Physical guarded action slots, without a permit backlog.";
              };
            };
          };
        };
        default = { };
        description = ''
          osctl-oomd configuration options
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          raw.restart_unknown_expiry_seconds > (if raw.interval == null then 5 else raw.interval)
          + raw.rtnl_watchdog.observation_max_age_seconds;
        message = "osctl.oomd restart_unknown_expiry_seconds must exceed interval + observation_max_age_seconds";
      }
      {
        assertion = !(raw ? restart_hits && raw.restart_after_seconds != null);
        message = "osctl.oomd restart_hits conflicts with restart_after_seconds";
      }
      {
        assertion = !(raw ? stop_hits && raw.stop_after_seconds != null);
        message = "osctl.oomd stop_hits conflicts with stop_after_seconds";
      }
      {
        assertion = !(raw.rtnl_watchdog.enable && raw.rtnl_watchdog ? restart_hits);
        message = "Enabled legacy RTNL restart_hits must migrate to the shared seconds budget";
      }
      {
        assertion =
          !raw.rtnl_watchdog.enable
          || (
            config.services.rtnl-watchdog.settings.latencyThresholdMs == raw.rtnl_watchdog.latency_threshold_ms
            && config.services.rtnl-watchdog.settings.intervalMs <= 1000
            && config.services.rtnl-watchdog.settings.tickMs <= 250
          );
        message = "oomd RTNL control requires matching cutoff and producer interval<=1000ms/tick<=250ms";
      }
    ];
    warnings =
      lib.optional (raw ? restart_hits || raw ? stop_hits)
        "Legacy oomd hit settings are translated to seconds; migrate to restart_after_seconds/stop_after_seconds."
      ++ lib.optional (
        !raw.rtnl_watchdog.enable && raw.rtnl_watchdog ? restart_hits
      ) "Disabled legacy RTNL restart_hits is obsolete.";
    services.rtnl-watchdog.enable = mkIf raw.rtnl_watchdog.enable true;
    services.rtnl-watchdog.settings.latencyThresholdMs = mkIf raw.rtnl_watchdog.enable (
      lib.mkDefault raw.rtnl_watchdog.latency_threshold_ms
    );

    runit.services.osctl-oomd = {
      run = ''
        waitForService osctld

        ${optionalString (!isNull rubyCrashReportTemplate) ''
          export RUBY_CRASH_REPORT=${escapeShellArg rubyCrashReportTemplate}
        ''}

        exec 2>&1
        exec ${pkgs.osctl-oomd}/bin/osctl-oomd --config ${configurationJson}
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
