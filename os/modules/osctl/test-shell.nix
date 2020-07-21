{ config, lib, pkgs, utils, ... }:
with lib;
let
  cfg = config.osctl.test-shell;
in {
  ###### interface

  options = {
    osctl.test-shell = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable test shell integration.
        '';
      };
    };
  };

  ###### implementation

  config = mkIf cfg.enable {
    runit.services.test-shell = {
      run = ''
        export PS1=""
        exec ${pkgs.bash}/bin/bash \
          --rcfile <(echo "echo test-shell-ready") \
          < /dev/hvc0 \
          > /dev/hvc0 \
          2>&1
      '';
      oneShot = true;
    };
  };
}
