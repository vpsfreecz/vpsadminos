variant:
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.networking.${variant};
  pkg = pkgs.${variant};

  kernel = cfg.protocol.kernel;
  birdc = if variant == "bird6" then "birdc6" else "birdc";

  concatNl = concatStringsSep "\n";
  concatIndent = indent: list:
    concatStringsSep
      "\n${indent}"
      (map (s: concatStringsSep "\n${indent}" (splitString "\n" s)) list);

  indentLines = indent: s: concatStringsSep "\n${indent}" (splitString "\n" s);

  bgpFragment = concatNl (flip mapAttrsToList cfg.protocol.bgp (proto: bgp: ''
    protocol bgp ${proto} {
      local as ${toString bgp.as};
      ${concatNl (mapAttrsToList (k: v: "neighbor ${k} as ${toString v};") bgp.neighbor)}
      ${optionalString bgp.nextHopSelf "next hop self;"}
      ${indentLines "  " bgp.extraConfig}
    }
  ''));

  bfdInterfacesFragment =
    concatNl (flip mapAttrsToList cfg.protocol.bfd.interfaces (k: v: ''
      interface "${k}" {
        min rx interval ${toString v.minRX} ms;
        min tx interval ${toString v.minTX} ms;
        idle tx interval ${toString v.idleTX} ms;
      };
    ''));

  bfdFragment = ''
    protocol bfd {
      ${bfdInterfacesFragment}
    }
  '';

  ospfAreaInterfaceFragment = interfaces:
    concatIndent "  " (flip mapAttrsToList interfaces (name: interface: ''
      interface "${name}" {
        ${indentLines "  " interface.extraConfig}
      };
    ''));

  ospfAreaFragment = areas:
    concatIndent "  " (flip mapAttrsToList areas (id: area: ''
      area ${id} {
        networks {
          ${concatStringsSep ";\n    " area.networks};
        };
        ${ospfAreaInterfaceFragment area.interface}
        ${indentLines "  " area.extraConfig}
      };
    ''));

  ospfFragment =
    concatNl (flip mapAttrsToList cfg.protocol.ospf (instance: ospf: ''
      protocol ospf ${instance} {
        ${ospfAreaFragment ospf.area}
        ${indentLines "  " ospf.extraConfig}
      }
    ''));

  birdConfig = ''
    router id ${cfg.routerId};
    log "${cfg.logFile}" ${cfg.logVerbosity};

    protocol kernel {
      ${optionalString kernel.persist "persist;"}
      ${optionalString kernel.learn "learn;"}
      scan time ${toString kernel.scanTime};
      ${indentLines "  " kernel.extraConfig}
    }

    protocol device {
      scan time ${toString cfg.protocol.device.scanTime};
    }

    ${optionalString cfg.protocol.direct.enable ''
    protocol direct {
      interface "${cfg.protocol.direct.interface}";
    }
    ''}

    ${optionalString (cfg.protocol.bgp != {}) bgpFragment}

    ${optionalString cfg.protocol.bfd.enable bfdFragment}

    ${optionalString (cfg.protocol.ospf != {}) ospfFragment}

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
      };

      minTX = mkOption {
        type = types.ints.positive;
        description = "The desired TX interval (milliseconds)";
        default = 100;
      };

      idleTX = mkOption {
        type = types.ints.positive;
        description = ''
          The desired TX interval if neighbor not available or not running BFD
          (milliseconds)
        '';
        default = 1000;
      };
    };
  };

  ospfAreaInterfaceOpts = { lib, pkgs, ... }: {
    options = {
      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra OSPF area interface config";
      };
    };
  };

  ospfAreaOpts = { lib, pkgs, ... }: {
    options = {
      networks = mkOption {
        type = types.listOf types.str;
        description = "Area networks";
      };

      interface = mkOption {
        type = types.attrsOf (types.submodule ospfAreaInterfaceOpts);
        description = "Interfaces";
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra OSPF area config";
      };
    };
  };

  ospfOpts = { lib, pkgs, ... }: {
    options = {
      version = mkOption {
        type = types.enum [ "v2" "v3" ];
        default = if variant == "bird" then "v2" else "v3";
        description = "OSPF version";
      };

      area = mkOption {
        type = types.attrsOf (types.submodule ospfAreaOpts);
        default = {};
        description = "OSPF areas";
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra OSPF instance config";
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
          enable = mkEnableOption "Enable protocol direct";

          interface = mkOption {
            type = types.str;
            default = "*";
            description = "Restrict devices used by direct protocol";
          };
        };

        bgp = mkOption {
          type = types.attrsOf (types.submodule bgpOpts);
          default = {};
          description = "BGP instances";
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
          };
        };

        ospf = mkOption {
          type = types.attrsOf (types.submodule ospfOpts);
          default = {};
          description = "OSPF instances";
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
      onChange = mkDefault "ignore";
    };

    users = {
      users.${variant} = {
        isSystemUser = true;
        description = "BIRD Internet Routing Daemon user";
        group = "${variant}";
      };
      extraGroups.${variant} = {};
    };
  };
}
