{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.osctl.oomd;

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
        };
        default = { };
        description = ''
          osctl-oomd configuration options
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    runit.services.osctl-oomd = {
      run = ''
        waitForService osctld

        exec 2>&1
        exec ${pkgs.osctl-oomd}/bin/osctl-oomd --config ${configurationJson}
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
