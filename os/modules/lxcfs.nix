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
        exec ${pkgs.lxcfs}/bin/lxcfs -l /var/lib/lxcfs
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
