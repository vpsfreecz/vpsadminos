{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  cfg = config.nix.daemon;
in
{
  ###### interface

  options = {
    nix.daemon = {
      enable = mkEnableOption "Enable nix daemon";
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf cfg.enable {
      runit.services.nix = {
        run = ''
          nix-store --load-db < /nix/store/nix-path-registration

          if ! isKernelParamSet nolive && [ ! -e /nix/var/nix/profiles/system ] ; then
            nix-env -p /nix/var/nix/profiles/system --set /run/current-system
          fi

          exec nix-daemon
        '';
        runlevels = [ "rescue" "default" ];
      };
    })
  ];
}
