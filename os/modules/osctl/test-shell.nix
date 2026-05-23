{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
with lib;
let
  cfg = config.osctl.test-shell;
  shellIndexes = range 0 (cfg.shells - 1);

  serviceName = i: if i == 0 then "test-shell" else "test-shell-${toString i}";
  device = i: "/dev/hvc${toString i}";
  shellService = i: {
    run = ''
      until [ -c ${device i} ] ; do
        echo "Waiting for ${device i}"
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

      exec < ${device i} > ${device i}
      exec 2>&1
      stty -F ${device i} raw -echo # prevent nl -> cr/nl conversion

      echo test-shell-ready

      exec ${pkgs.bash}/bin/bash --norc ${device i}
    '';
    oneShot = true;
    onChange = "ignore";
  };
in
{
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

      shells = mkOption {
        type = types.ints.positive;
        default = 1;
        description = ''
          Number of test shells to run.
        '';
      };
    };
  };

  ###### implementation

  config = mkIf cfg.enable {
    runit.services = listToAttrs (map (i: nameValuePair (serviceName i) (shellService i)) shellIndexes);
  };
}
