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
          if [ -e /nix-path-registration ] ; then
            nix-store --load-db < /nix-path-registration
            rm -f /nix-path-registration
          fi

          if ! isKernelParamSet nolive && [ ! -e /nix/var/nix/profiles/system ] ; then
            nix-env -p /nix/var/nix/profiles/system --set /run/current-system
          fi

          ln -sf /nix/var/nix/profiles /nix/var/nix/gcroots/profiles

          exec nix-daemon
        '';
        runlevels = [ "rescue" "default" ];
      };

      system.activationScripts.nix = mkForce (stringAfter [ "etc" "users" ]
        ''
          install -m 0755 -d /nix/var/nix/{gcroots,profiles}/per-user

          # Subscribe the root user to the NixOS and vpsAdminOS channel by default.
          if [ ! -e "/root/.nix-channels" ]; then
              echo "${config.system.defaultChannel} nixos" > "/root/.nix-channels"
              echo "${config.system.defaultOsChannel} vpsadminos" >> "/root/.nix-channels"
          fi
        '');
    })
  ];
}
