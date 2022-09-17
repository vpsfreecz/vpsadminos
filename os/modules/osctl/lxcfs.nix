{ config, lib, pkgs, utils, ... }:
with lib;
{
  config = {
    runit.services.osctl-lxcfs = {
      run = ''
        statedir=/run/osctl/lxcfs
        mkdir -p -m 0711 $statedir
        mkdir -p "$statedir/mountpoint"
        mkdir -p "$statedir/runsvdir"
        mkdir -p "$statedir/servers"
        exec runsvdir "$statedir/runsvdir"
      '';

      onChange = "ignore";

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
