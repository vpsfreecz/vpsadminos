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

      db = mkOption {
        type = types.submodule {
          options = {
            host = mkOption {
              type = types.str;
              description = "Database hostname";
            };

            user = mkOption {
              type = types.str;
              description = "Database user";
            };

            password = mkOption {
              type = types.str;
              description = "Database password";
            };

            name = mkOption {
              type = types.str;
              description = "Database name";
            };
          };
        };
        default = {
          host = "";
          user = "";
          password = "";
          name = "";
        };
        description = ''
          Database credentials. Don't use this for production deployments, as
          the credentials would be world readable in the Nix store.
          Pass the database credentials through deployment.keys.nodectld-config
          in NixOps.
        '';
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
        ${lib.optionalString (cfg.db.host != "") ''
        :db:
          :host: ${cfg.db.host}
          :user: ${cfg.db.user}
          :pass: ${cfg.db.password}
          :name: ${cfg.db.name}
        ''}
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
