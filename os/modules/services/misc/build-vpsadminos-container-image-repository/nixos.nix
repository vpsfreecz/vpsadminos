{
  config,
  pkgs,
  lib,
  ...
}:
with lib;
let
  cfg = config.services.build-vpsadminos-container-image-repository;
  vpsadminosFlake = builtins.getFlake (toString ../../../../..);

  shared = import ./shared.nix { inherit config pkgs lib; };

  repoModule =
    { config, ... }:
    {
      options = {
        systemd.timer = {
          enable = mkEnableOption "Enable systemd timer to build the repository";

          onCalendar = mkOption {
            type = types.str;
            default = "Sat 04:00:00";
            description = ''
              systemd timer OnCalendar setting
            '';
          };
        };
      };
    };
in
{
  imports = [
    ./options.nix
  ];

  options = {
    services.build-vpsadminos-container-image-repository = mkOption {
      type = types.attrsOf (types.submodule repoModule);
    };
  };

  config = {
    nixpkgs.overlays = [
      vpsadminosFlake.overlays.osctl
      vpsadminosFlake.overlays.ruby
    ];

    environment.systemPackages = shared.createSystemPackages cfg;

    systemd.services = shared.createSystemdServices cfg;
    systemd.timers = shared.createSystemdTimers cfg;
  };
}
