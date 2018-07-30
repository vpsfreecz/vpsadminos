{ config, lib, pkgs, ... }:
with lib;

let
  generic = variant:
    let
      cfg = config.networking.${variant};
      pkg = pkgs.${variant};
      kernel = cfg.protocol.kernel;
      birdc = if variant == "bird6" then "birdc6" else "birdc";
      concatNl = concatStringsSep "\n";
      mkNeighbor = x: concatNl (mapAttrsToList (k: v: "neighbor ${k} as ${toString v};") x);
      bgps = concatNl (mapAttrsToList (k: v: ''
        protocol bgp ${k} {
          local as ${toString v.as};
          ${mkNeighbor v.neighbor}
          ${optionalString v.nextHopSelf "next hop self;"}
          ${v.extraConfig}
        }

        '') cfg.protocol.bgp);

      bird_config = ''
        router id ${cfg.routerId};
        log "${cfg.logFile}" ${cfg.logVerbosity};
        protocol kernel {
            ${optionalString kernel.persist "persist;"}
            ${optionalString kernel.learn "learn;"}
            scan time ${toString kernel.scanTime};
            ${kernel.extraConfig}
        }

        protocol device {
                scan time 1;
        }

        ${bgps}

        ${cfg.extraConfig}
      '';

      configFile = pkgs.stdenv.mkDerivation {
        name = "${variant}.conf";
        text = bird_config;
        preferLocalBuild = true;
        buildCommand = ''
          echo -n "$text" > $out
          cat $out
          sed -i -e "/log/d" $out
          ${pkg}/bin/${variant} -d -p -c $out
        '';
      };
    in {
      ###### interface
      options = {
        networking.${variant} = {
          enable = mkEnableOption "BIRD Internet Routing Daemon";
          routerId = mkOption {
            type = types.string;
          };
          logFile = mkOption {
            type = types.string;
            default = "/var/log/${variant}.log";
          };
          logVerbosity = mkOption {
            type = types.string;
            default = "all";
          };
          protocol = {
            kernel = {
              persist = mkEnableOption "";
              learn = mkEnableOption "";
              scanTime = mkOption {
                type = types.ints.positive;
                default = 10;
              };
              extraConfig = mkOption {
                type = types.lines;
                default = "";
              };

            };
            device = {
              scanTime = mkOption {
                type = types.ints.positive;
                default = 10;
              };
              extraConfig = mkOption {
                type = types.lines;
                default = "";
              };

            };
            bgp = mkOption {
              type = types.unspecified;
            };

          };
          extraConfig = mkOption {
            type = types.lines;
            default = "";
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

        runit.services."${variant}".run = ''
          #!/bin/sh
          touch ${cfg.logFile}
          chown ${variant}:${variant} ${cfg.logFile}
          chmod 660 ${cfg.logFile}
          exec ${pkg}/bin/${variant} -c ${configFile} -u ${variant} -g ${variant} -f
        '';

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
