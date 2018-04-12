{ lib, pkgs, config, ... }:

with lib;

let
  kernelModules = lib.concatStringsSep " " config.boot.initrd.kernelModules;
in
{
  options = {
    boot = {
      # *Size are unused for now
      #devSize = mkOption {
      #  default = "5%";
      #  example = "32m";
      #  type = types.str;
      #};
      #devShmSize = mkOption {
      #  default = "50%";
      #  example = "256m";
      #  type = types.str;
      #};
      #runSize = mkOption {
      #  default = "25%";
      #  example = "256m";
      #  type = types.str;
      # };

      procHidePid = mkOption {
        type = types.bool;
        default = false;
        description = "mount proc with hidepid=2";
      };

      postActivate = mkOption {
        type = types.str;
        default = "";
        description = ''
          Shell commands executed after system activation, right before the
          control is given to runit.
        '';
      };
    };
  };
  config = {
    system.build.bootStage2 = pkgs.substituteAll {
      src = ./stage-2-init.sh;
      isExecutable = true;
      path = config.system.path;
      inherit (config.networking) hostName;
      inherit (config.boot) procHidePid;
      inherit (config.boot) postActivate;
    };
  };
}
