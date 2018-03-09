{ config, lib, pkgs, utils, ... }:

with utils;
with lib;

let

  cfg = config.vpsadmin;

in

{

  ###### interface

  options = {
    vpsadmin = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable vpsAdmin integration, i.e. include nodectld and nodectl
        '';
      };
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf cfg.enable {
      environment.etc."service/nodectld/run".source = pkgs.writeScript "nodectld" ''
        #!/bin/sh
        exec 2>&1
        exec ${pkgs.nodectld}/bin/nodectld
      '';
        
      environment.systemPackages = [ pkgs.nodectl ];
    })
  ];
}
