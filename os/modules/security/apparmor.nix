{ config, lib, ... }:
let
  inherit (lib) literalExpression mdDoc mkAfter mkDefault mkIf mkMerge mkOption types;

  cfg = config.security.apparmor;
in {
  options = {
    security.apparmor = {
      enableOnBoot = mkOption {
        type = types.bool;
        defaultText = literalExpression "config.security.apparmor.enable";
        description = mdDoc ''
          Enable apparmor using kernel command line parameters

          Using this option, it is possible to keep {option}`security.apparmor.enable`
          on to preserve apparmor on already running systems, but prevent apparmor
          from being activated on boot.
        '';
      };
    };
  };

  config = mkMerge [
    {
      security.apparmor.enableOnBoot = mkDefault config.security.apparmor.enable;
    }

    (mkIf (cfg.enable && !cfg.enableOnBoot) {
      boot.kernelParams = mkAfter [ "apparmor=0" "security=none" ];
    })
  ];
}
