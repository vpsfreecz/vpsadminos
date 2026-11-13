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

  configurationJson = settingsFormat.generate "osctl-oomd-config.json" cfg.settings;
in
{
  options = {
    osctl.oomd = {
      enable = mkEnableOption "Enable osctl-oomd";

      settings = mkOption {
        type = types.submodule {
          freeformType = settingsFormat.type;
          options.rtnl_watchdog = {
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
            restart_hits = mkOption {
              type = types.ints.between 2 2147483647;
              default = 2;
              description = "Fresh raw hits required within a watchdog episode.";
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
        default = { };
        description = ''
          osctl-oomd configuration options
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    osctl.rtnlWatchdog.enable = mkIf cfg.settings.rtnl_watchdog.enable true;

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
