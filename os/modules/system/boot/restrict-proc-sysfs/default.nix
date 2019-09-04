{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.system.boot.restrict-proc-sysfs;

  restrictProcSysfs = pkgs.callPackage ../restrict-dirs.nix {
    data = cfg.config;
  };
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
        type = types.attrs;
        default = (import ./config.nix);
        description = ''
          Config passed to ../restrict-dirs.nix
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    runit.services.restrict-proc-sysfs = {
      run = ''
        sleep 10
        ${restrictProcSysfs}
      '';
      oneShot = true;
    };
  };
}
