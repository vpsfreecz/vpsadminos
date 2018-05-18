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

      dbHost = mkOption {
        type = types.str;
        description = "Database hostname";
      };

      dbUser = mkOption {
        type = types.str;
        description = "Database user";
      };

      dbPassword = mkOption {
        type = types.str;
        description = "Database password";
      };

      dbName = mkOption {
        type = types.str;
        description = "Database name";
      };

      nodeId = mkOption {
        type = types.int;
        description = "Node ID";
      };

      netInterfaces = mkOption {
        type = types.listOf types.str;
        description = "Network interfaces";
      };

      consoleHost = mkOption {
        type = types.str;
        description = "Address for console server to listen on";
      };
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf cfg.enable {
      environment.etc."vpsadmin/nodectld.yml".source = pkgs.writeText "nodectld-conf" ''
        :db:
          :host: ${cfg.dbHost}
          :user: ${cfg.dbUser}
          :pass: ${cfg.dbPassword}
          :name: ${cfg.dbName}

        :vpsadmin:
          :node_id: ${toString cfg.nodeId}
          :net_interfaces: [${lib.concatStringsSep ", " cfg.netInterfaces}]

        :console:
          :host: ${cfg.consoleHost}
      '';

      environment.etc."service/nodectld/run".source = pkgs.writeScript "nodectld-service" ''
        #!/bin/sh
        export HOME=${config.users.extraUsers.root.home}
        exec 2>&1
        exec ${pkgs.nodectld}/bin/nodectld --log syslog --log-facility local3 --export-console
      '';
        
      environment.systemPackages = [ pkgs.nodectl ];
    })
  ];
}
