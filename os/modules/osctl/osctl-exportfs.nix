{ config, lib, pkgs, utils, ... }:
with lib;
let
  cfg = config.osctl.exportfs;
in {
  ###### interface

  options = {
    osctl.exportfs = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable osctl-exportfs integration.
        '';
      };
    };
  };

  ###### implementation

  config = mkIf cfg.enable {
    runit.services.osctl-exportfs = {
      run = ''
        statedir=/run/osctl/exportfs

        mkdir -p "$statedir"
        chmod 0750 "$statedir"
        mkdir -p "$statedir/rootfs"
        mkdir -p "$statedir/runsvdir"
        mkdir -p "$statedir/servers"

        exec runsvdir "$statedir/runsvdir"
      '';
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };

    environment.systemPackages = with pkgs; [
      osctl-exportfs
    ];
  };
}
