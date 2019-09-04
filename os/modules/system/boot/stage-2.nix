{ lib, pkgs, config, ... }:

with lib;

let
  kernelModules = lib.concatStringsSep " " config.boot.initrd.kernelModules;
  postBootCommands = pkgs.writeText "local-cmds" ''
    ${config.boot.postBootCommands}
  '';
in
{
  options = {
    boot = {
      postBootCommands = mkOption {
        default = "";
        example = "rm -f /var/log/messages";
        type = types.lines;
        description = ''
          Shell commands to be executed just before runit is started.
        '';
      };

      # *Size are unused for now
      devSize = mkOption {
        default = "5%";
        example = "32m";
        type = types.str;
      };
      devShmSize = mkOption {
        default = "50%";
        example = "256m";
        type = types.str;
      };
      runSize = mkOption {
        default = "25%";
        example = "256m";
        type = types.str;
       };

      procHidePid = mkOption {
        type = types.bool;
        default = false;
        description = "mount proc with hidepid=2";
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
      inherit postBootCommands;
      restrictProcSysfs = pkgs.callPackage ./restrict-dirs.nix {
        data = config.system.boot.restrict-proc-sysfs.config;
      };
    };
  };
}
