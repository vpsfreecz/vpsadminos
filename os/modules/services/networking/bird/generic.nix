variant:
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.networking.${variant};
  pkg = pkgs.${variant};

  kernel = cfg.protocol.kernel;
  birdc = if variant == "bird6" then "birdc6" else "birdc";

  concatNl = concatStringsSep "\n";

  birdConfig = ''
    router id ${cfg.routerId};
    log "${cfg.logFile}" ${cfg.logVerbosity};
    protocol kernel {
        ${optionalString kernel.persist "persist;"}
        ${optionalString kernel.learn "learn;"}
        scan time ${toString kernel.scanTime};
        ${kernel.extraConfig}
    }

    protocol device {
        scan time ${toString cfg.protocol.device.scanTime};
    }

    protocol direct {
        interface "${cfg.protocol.direct.interface}";
    }

    ${cfg.protocol.bgp}
    ${optionalString cfg.protocol.bfd.enable ''
      protocol bfd {
        ${cfg.protocol.bfd.interfaces}
      }
    ''}

    ${cfg.extraConfig}
  '';

  configFile = pkgs.stdenv.mkDerivation {
    name = "${variant}.conf";
    text = birdConfig;
    preferLocalBuild = true;
    buildCommand = ''
      echo -n "$text" > $out
      cat $out
      sed -i -e "/log/d" $out
      ${pkg}/bin/${variant} -d -p -c $out
    '';
  };

  bgpOpts = { lib, pkgs, ... }: {
    options = {
      as = mkOption {
        type = types.ints.positive;
        description = "BGP autonomous system ID";
      };

      nextHopSelf = mkOption {
        type = types.bool;
        description = "Always advertise our own local address as a next hop";
        default = false;
      };

      neighbor = mkOption {
        type = types.attrsOf types.ints.positive;
        description = "Our neighbors";
        apply = x: concatNl (mapAttrsToList (k: v:
          "neighbor ${k} as ${toString v};") x);
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
      };
    };
  };

  bfdInterfaceOpts = { lib, pkgs, ... }: {
    options = {
      minRX = mkOption {
        type = types.ints.positive;
        description = "The minimum RX interval (milliseconds)";
        default = 10;
        apply = x: "min rx interval ${toString x} ms;";
      };

      minTX = mkOption {
        type = types.ints.positive;
        description = "The desired TX interval (milliseconds)";
        default = 100;
        apply = x: "min tx interval ${toString x} ms;";
      };

      idleTX = mkOption {
        type = types.ints.positive;
        description = ''
          The desired TX interval if neighbor not available or not running BFD
          (milliseconds)
        '';
        default = 1000;
        apply = x: "idle tx interval ${toString x} ms;";
      };
    };
  };

in {
  ###### interface
  options = {
    networking.${variant} = {
      enable = mkEnableOption "BIRD Internet Routing Daemon";

      routerId = mkOption {
        type = types.str;
        description = ''
          Set BIRD's router ID based on an IP address of an interface specified
          by an interface pattern.
        '';
      };

      logFile = mkOption {
        type = types.str;
        default = "/var/log/${variant}.log";
      };

      logVerbosity = mkOption {
        type = types.str;
        default = "all";
      };

      protocol = {
        kernel = {
          persist = mkEnableOption ''
            Tell BIRD to leave all its routes in the routing tables when it
            exits (instead of cleaning them up).
          '';

          learn = mkEnableOption ''
            Enable learning of routes added to the kernel routing tables by
            other routing daemons or by the system administrator.
          '';

          scanTime = mkOption {
            type = types.ints.positive;
            default = 10;
            description = ''
              Time in seconds between two consecutive scans of the kernel
              routing table.
            '';
          };

          extraConfig = mkOption {
            type = types.lines;
            default = "";
            description = "Extra config for kernel protocol";
          };
        };

        device = {
          scanTime = mkOption {
            type = types.ints.positive;
            default = 1;
            description = ''
              Time in seconds between two scans of the network interface list.
            '';
          };

          extraConfig = mkOption {
            type = types.lines;
            default = "";
            description = "Extra config for device protocol";
          };
        };

        direct = {
          interface = mkOption {
            type = types.str;
            default = "*";
            description = "Restrict devices used by direct protocol";
          };
        };

        bgp = mkOption {
          type = types.attrsOf (types.submodule bgpOpts);
          description = "BGP instances";
          apply = x: concatNl (flip mapAttrsToList x (k: v:
            ''
              protocol bgp ${k} {
                local as ${toString v.as};
                ${v.neighbor}
                ${optionalString v.nextHopSelf "next hop self;"}
                ${v.extraConfig}
              }
            ''));
        };

        bfd = {
          enable = mkOption {
            type = types.bool;
            description = "Enable BFD";
            default = false;
          };

          interfaces = mkOption {
            type = types.attrsOf (types.submodule bfdInterfaceOpts);
            description = "BFD interfaces";
            apply = x: concatNl (flip mapAttrsToList x (k: v:
              ''
                interface "${k}" {
                  ${v.minRX}
                  ${v.minTX}
                  ${v.idleTX}
                };
              ''));
          };
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

    environment.etc."${variant}.conf".source = configFile;

    runit.services."${variant}" = {
      run = ''
        touch ${cfg.logFile}
        chown ${variant}:${variant} ${cfg.logFile}
        chmod 660 ${cfg.logFile}
        exec ${pkg}/bin/${variant} -c /etc/${variant}.conf -u ${variant} -g ${variant} -f
      '';
      runlevels = [ "rescue" "default" ];
    };

    users = {
      users.${variant} = {
        description = "BIRD Internet Routing Daemon user";
        group = "${variant}";
      };
      extraGroups.${variant} = {};
    };
  };
}
