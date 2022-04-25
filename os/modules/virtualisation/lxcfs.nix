{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

{
  ###### interface

  options = {
  };

  ###### implementation

  config = {
    runit.services.lxcfs = {
      run = ''
        mkdir -p /var/lib/lxcfs
        umount /var/lib/lxcfs 2> /dev/null
        exec ${pkgs.lxcfs}/bin/lxcfs --enable-loadavg --enable-cfs /var/lib/lxcfs
      '';

      onChange = "reload";
      reloadMethod = "1";

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
