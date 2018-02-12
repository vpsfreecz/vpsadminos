{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  generic = variant:
    let
      cfg = config.networking.${variant};
      pkg = pkgs.${variant};
      birdc = if variant == "bird6" then "birdc6" else "birdc";
      bird_config = ''
        protocol kernel {
            persist;                # Don't remove routes on BIRD shutdown
            scan time 20;           # Scan kernel routing table every 20 seconds
            export all;             # Default is export none
        }

        protocol device {
                scan time 10;       # Scan interfaces every 10 seconds
        }
      '';

      configFile = pkgs.stdenv.mkDerivation {
        name = "${variant}.conf";
        text = cfg.config;
        preferLocalBuild = true;
        buildCommand = ''
          echo -n "$text" > $out
          ${pkg}/bin/${variant} -d -p -c $out
        '';
      };
    in {
      ###### interface
      options = {
        networking.${variant} = {
          enable = mkEnableOption "BIRD Internet Routing Daemon";
          config = mkOption {
            type = types.lines;
            default = bird_config;
            description = ''
              BIRD Internet Routing Daemon configuration file.
              <link xlink:href='http://bird.network.cz/'/>
            '';
          };
        };
      };

      ###### implementation
      config = mkIf cfg.enable {
        environment.systemPackages = [ pkg ];
        environment.etc = {
          "service/${variant}/run".source = pkgs.writeScript "${variant}" ''
            #!/bin/sh
            mkdir -p /var/run/
            ${pkg}/bin/${variant} -c ${configFile} -u ${variant} -g ${variant} -f
          '';
        };

        users = {
          extraUsers.${variant} = {
            description = "BIRD Internet Routing Daemon user";
            group = "${variant}";
          };
          extraGroups.${variant} = {};
        };

      };
    };

  inherit (config.networking) bird bird6;
in {
  imports = [(generic "bird") (generic "bird6")];
}
