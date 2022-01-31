{ config, lib, pkgs, utils, ... }:
with lib;

{
  config = {
    runit.services.livepatches = {
      run = ''
        modprobe ${pkgs.livepatch-cpu-fakemask}/*.ko
      '';
      oneShot = true;
      runlevels = [ "default" ];
    };
  };
}

