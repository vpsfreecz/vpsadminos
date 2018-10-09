{ config, lib, pkgs, ... }:

with lib;

let

  cfg = config.services.haveged;

in


{

  ###### interface

  options = {

    services.haveged = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable to haveged entropy daemon, which refills
          /dev/random when low.
        '';
      };

      refill_threshold = mkOption {
        type = types.int;
        default = 1024;
        description = ''
          The number of bits of available entropy beneath which
          haveged should refill the entropy pool.
        '';
      };

    };

  };


  ###### implementation

  config = mkIf cfg.enable {

    runit.services.haveged = {
      run = ''
        exec ${pkgs.haveged}/bin/haveged -F -w ${toString cfg.refill_threshold} -v 1
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };

  };

}
