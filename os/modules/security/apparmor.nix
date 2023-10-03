{ config, lib, ... }:
let
  inherit (lib) literalExpression mdDoc mkAfter mkIf mkOption types;

  cfg = config.security.apparmor;
in {
  options = {
    security.apparmor = {
      enableOnBoot = mkOption {
        type = types.bool;
        default = false;
        description = mdDoc ''
          Enable apparmor using kernel command line parameters

          Using this option, it is possible to keep {option}`security.apparmor.enable`
          on to preserve apparmor on already running systems, but prevent apparmor
          from being activated on boot.
        '';
      };
    };
  };

  config = mkIf (cfg.enable && !cfg.enableOnBoot) {
    boot.kernelParams = mkAfter [ "apparmor=0" "security=none" ];
  };
}
