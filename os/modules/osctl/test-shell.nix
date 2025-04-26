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
        until [ -c /dev/hvc0 ] ; do
          echo "Waiting for /dev/hvc0"
          sleep 1
        done

        export USER=root
        export HOME=/root

        if [ -e /etc/profile ]; then
          source /etc/profile
        fi

        export PAGER=
        export PS1=

        cd /tmp

        exec < /dev/hvc0 > /dev/hvc0
        exec 2>&1
        stty -F /dev/hvc0 raw -echo # prevent nl -> cr/nl conversion

        echo test-shell-ready

        exec ${pkgs.bash}/bin/bash --norc /dev/hvc0
      '';
      oneShot = true;
    };
  };
}
