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
      environment.etc."service/rpcbind/run".source = pkgs.writeScript "rpcbind_run" ''
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
