{ pkgs, config, lib, ... }:
with lib;
let
  cfg = config.networking;

in {
  options = {
    networking = {
      hostName = mkOption {
        type = types.str;
        description = "machine hostname";
        default = "default";
      };

      preConfig = mkOption {
        type = types.lines;
        description = "Set of commands run prior to any other network configuration";
        default = "";
      };

      custom = mkOption {
        type = types.lines;
        description = "Custom set of commands used to set-up networking";
        default = "";
        example = "
          ip addr add 10.0.0.1 dev ix0
          ip link set ix0 up
        ";
      };

      static = {
        enable = mkOption {
          type = types.bool;
          description = "use static networking configuration";
          default = false;
        };

        interface = mkOption {
          type = types.str;
          description = "interface for static networking configuration";
          default = "eth0";
        };

        ip = mkOption {
          type = types.str;
          description = "IP address for static networking configuration";
          default = "10.0.2.15";
        };

        route = mkOption {
          type = types.str;
          description = "route";
          default = "10.0.2.0/24";
        };

        gw = mkOption {
          type = types.str;
          description = "gateway IP address for static networking configuration";
          default = "10.0.2.2";
        };
      };

      dhcp = mkOption {
        type = types.bool;
        description = "use DHCP to obtain IP";
        default = false;
      };

      lxcbr = mkOption {
        type = types.bool;
        description = "create lxc bridge interface";
        default = false;
      };

      nat = mkOption {
        type = types.bool;
        description = "enable NAT for containers";
        default = true;
      };

      hosts = lib.mkOption {
        type = types.attrsOf ( types.listOf types.str );
        default = {};
        example = literalExample ''
          {
            "127.0.0.1" = [ "foo.bar.baz" ];
            "192.168.0.2" = [ "fileserver.local" "nameserver.local" ];
          };
        '';
        description = ''
          Locally defined maps of hostnames to IP addresses.
        '';
      };

      extraHosts = lib.mkOption {
        type = types.lines;
        default = "";
        example = "192.168.0.1 lanlocalhost";
        description = ''
          Additional verbatim entries to be appended to <filename>/etc/hosts</filename>.
        '';
      };

      nameservers = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["208.67.222.222" "208.67.220.220"];
        description = ''
          The list of nameservers.  It can be left empty if it is auto-detected through DHCP.
        '';
      };

      search = mkOption {
        default = [];
        example = [ "example.com" "local.domain" ];
        type = types.listOf types.str;
        description = ''
          The list of search paths used when resolving domain names.
        '';
      };

      domain = mkOption {
        default = null;
        example = "home";
        type = types.nullOr types.str;
        description = ''
          The domain.  It can be left empty if it is auto-detected through DHCP.
        '';
      };
    };
  };

  config = {
    boot.kernelModules = optionals cfg.nat [
      "ip_tables"
      "iptable_nat"
      "ip6_tables"
      "ip6table_nat"
    ];

    environment.etc = {
      # /etc/hosts: Hostname-to-IP mappings.
      "hosts".text =
        let
            oneToString = set : ip : ip + " " + concatStringsSep " " ( getAttr ip set );
            allToString = set : concatMapStringsSep "\n" ( oneToString set ) ( attrNames set );
            userLocalHosts = optionalString
              ( builtins.hasAttr "127.0.0.1" cfg.hosts )
              ( concatStringsSep " " ( remove "localhost" cfg.hosts."127.0.0.1" ));
            userLocalHosts6 = optionalString
              ( builtins.hasAttr "::1" cfg.hosts )
              ( concatStringsSep " " ( remove "localhost" cfg.hosts."::1" ));
            otherHosts = allToString ( removeAttrs cfg.hosts [ "127.0.0.1" "::1" ]);
        in
        ''
          127.0.0.1 ${userLocalHosts} localhost
          ${optionalString cfg.enableIPv6 ''
            ::1 ${userLocalHosts6} localhost
          ''}
          ${otherHosts}
          ${cfg.extraHosts}
        '';

      "resolv.conf".text = lib.mkDefault ''
          ${optionalString (cfg.nameservers != [] && cfg.domain != null) ''
            domain ${cfg.domain}
          ''}
          ${optionalString (cfg.search != []) ("search " + concatStringsSep " " cfg.search)}
          ${flip concatMapStrings cfg.nameservers (ns: ''
            nameserver ${ns}
          '')}
        '';
    };

    runit.services.networking = {
      run = ''
        ensureServiceStarted eudev-trigger

        ${cfg.preConfig}

        ${optionalString cfg.static.enable ''
        ip addr add ${cfg.static.ip} dev ${cfg.static.interface}
        ip link set ${cfg.static.interface} up
        ip route add ${cfg.static.route} dev ${cfg.static.interface}
        ip route add default via ${cfg.static.gw} dev ${cfg.static.interface}
        ''}

        ${optionalString cfg.dhcp ''
        ${pkgs.dhcpcd}/sbin/dhcpcd
        ''}

        ${optionalString cfg.lxcbr ''
        brctl addbr lxcbr0
        brctl setfd lxcbr0 0
        ip addr add 192.168.1.1 dev lxcbr0
        ip link set promisc on lxcbr0
        ip link set lxcbr0 up
        ip route add 192.168.1.0/24 dev lxcbr0
        ''}

        ${cfg.custom}
      '';
      oneShot = true;
      onChange = "ignore";
      runlevels = [ "rescue" "default" ];
    };

    runit.services.network-online = {
      run = ''
        ensureServiceStarted networking

        wait_online() {
          for i in {1..450} ; do
            sleep 1
            ping -c 1 8.8.8.8 >/dev/null 2>&1 && return 0
            warn "Waiting for network to come online..."

            sleep 1
            ping -c 1 1.1.1.1 >/dev/null 2>&1 && return 0
            warn "Waiting for network to come online..."
          done

          return 1
        }

        if ! wait_online ; then
          warn "Timed out while waiting for network to come online"
          exit 1
        fi
      '';
      oneShot = true;
      onChange = "ignore";
      runlevels = [ "rescue" "default" ];
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };

    networking.firewall.extraCommands = optionalString cfg.lxcbr ''
      iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    '';
  };
}
