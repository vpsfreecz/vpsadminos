{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.manual;
  manual = import ../../manual { inherit pkgs; };
in {
  options = {
    manual.html.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to install the HTML manual.
      '';
    };

    manual.manpages.enable = mkOption {
      type = types.bool;
      default = true;
      example = false;
      description = ''
        Whether to install the configuration manual page. The manual can
        be reached by <command>man vpsadminos-configuration.nix</command>.
      '';
    };

    manual.json.enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Whether to install a JSON formatted list of all vpsAdminOS
        options. This can be located at
        <filename>&lt;profile directory&gt;/share/doc/vpsadminos/options.json</filename>,
        and may be used for navigating definitions, auto-completing,
        and other miscellaneous tasks.
      '';
    };
  };

  config = {
    environment.systemPackages = mkMerge [
      (mkIf cfg.html.enable [ manual.html ])
      (mkIf cfg.manpages.enable [ manual.manPages ])
      (mkIf cfg.json.enable [ manual.options.json ])
    ];
  };
}
