{ pkgs, config, lib, ... }:
with lib;
let
  cfg = config.networking;

  quoteStrings = list: map (v: "\"${v}\"") list;

  waitOnlineMethods = {
    ping = ''
      check_online_ping() {
        for host in ${toString (quoteStrings cfg.waitOnline.ping.hosts)} ; do
          sleep 1
          ping -c 1 "$host" >/dev/null 2>&1 && return 0
        done

        return 1
      }
    '';

    http = ''
      check_online_http() {
        for url in ${toString (quoteStrings cfg.waitOnline.http.urls)} ; do
          sleep 1
          ${pkgs.curl}/bin/curl --head "$url" >/dev/null 2>&1 && return 0
        done

        return 1
      }
    '';
  };
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

        gateway = mkOption {
          type = types.str;
          description = "Gateway IP address for static networking configuration";
          default = "10.0.2.2";
        };
      };

      useDHCP = mkOption {
        type = types.bool;
        description = "Use DHCP to obtain IP address";
        default = false;
      };

      lxcbr = {
        enable = mkOption {
          type = types.bool;
          description = "Create bridge interface for containers";
          default = false;
        };

        enableDHCPServer = mkOption {
          type = types.bool;
          description = "Enable DHCP server on bridge interface for containers";
          default = config.networking.lxcbr.enable;
        };
      };

      hosts = lib.mkOption {
        type = types.attrsOf ( types.listOf types.str );
        default = {};
        example = literalExpression ''
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

      waitOnline = {
        methods = mkOption {
          type = types.listOf (types.enum [ "ping" "http" ]);
          default = [ "ping" "http" ];
          description = ''
            Which methods to use to check network connectivity. It is enough
            for one method to work.
          '';
        };

        ping.hosts = mkOption {
          type = types.listOf types.str;
          default = [ "8.8.8.8" "1.1.1.1" ];
          description = ''
            A list of hosts which are pinged. We are online when any one of these
            pongs back.
          '';
        };

        http.urls = mkOption {
          type = types.listOf types.str;
          default = [ "http://1.1.1.1" "http://vpsadminos.org" ];
          description = ''
            A list URLs which are queried. We are online when any one of these
            sends a HTTP response.
          '';
        };
      };
    };
  };

  config = {
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
        ${cfg.preConfig}

        ${optionalString cfg.static.enable ''
        ip addr add ${cfg.static.ip} dev ${cfg.static.interface}
        ip link set ${cfg.static.interface} up
        ip route add ${cfg.static.route} dev ${cfg.static.interface}
        ip route add default via ${cfg.static.gateway} dev ${cfg.static.interface}
        ''}

        ${optionalString cfg.lxcbr.enable ''
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

    runit.services.dhcpcd = mkIf cfg.useDHCP {
      run = ''
        ensureServiceStarted eudev-trigger
        ensureServiceStarted networking

        exec ${pkgs.dhcpcd}/sbin/dhcpcd -B
      '';
      runlevels = [ "rescue" "default" ];
    };

    runit.services.network-online = {
      run = ''
        ensureServiceStarted networking

        ${concatMapStringsSep "\n\n" (m: waitOnlineMethods.${m}) cfg.waitOnline.methods}

        wait_online() {
          for i in {1..300} ; do
            for method in ${toString cfg.waitOnline.methods} ; do
              check_online_$method && return 0
            done

            warn "Waiting for network to come online..."
            sleep 1
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
      runlevels = [ "default" ];
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };

    networking.firewall.extraCommands = optionalString cfg.lxcbr.enable ''
      iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    '';
  };
}
