{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  cfg = config.services.rpcbind;
in
{
  ###### interface

  options = {
    services.rpcbind = {
      enable = mkEnableOption "Enable rpcbind service";
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf cfg.enable {
      runit.services.rpcbind.run = ''
        #!/bin/sh
        exec ${pkgs.rpcbind}/bin/rpcbind -f
      '';

      environment.systemPackages = [ pkgs.rpcbind ];

      users.users.rpc = {
        group = "nogroup";
        uid = config.ids.uids.rpc;
      };
    })
  ];
}
