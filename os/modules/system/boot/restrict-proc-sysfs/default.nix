{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.system.boot.restrict-proc-sysfs;

  restrictProcSysfs = pkgs.callPackage ./restrict-dirs.nix {};

  configFile = pkgs.writeText "restrict-proc-sysfs-config.txt" cfg.config;
in {
  options = {
    system.boot.restrict-proc-sysfs = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Restrict proc and sysfs contents
        '';
      };

      config = mkOption {
        type = types.lines;
        default = builtins.readFile ./config.txt;
        description = ''
          Config passed to ./restrict-dirs.rb
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    runit.services.restrict-proc-sysfs = {
      run = ''
        sleep 10
        ${restrictProcSysfs} ${configFile}
      '';
      oneShot = true;
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
