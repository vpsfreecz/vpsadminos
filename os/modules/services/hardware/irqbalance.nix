{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf;

  cfg = config.services.irqbalance;
in
{
  options = {
    services.irqbalance.enable = mkEnableOption "irqbalance daemon";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.irqbalance ];

    runit.services.irqbalance = {
      run = ''
        mkdir -p /run/irqbalance
        exec ${pkgs.irqbalance}/bin/irqbalance -f
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}