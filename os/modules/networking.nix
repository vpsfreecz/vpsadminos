{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  cfg = config.networking;
in
{
  ###### interface

  options = {
    networking.hosts = lib.mkOption {
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

    networking.extraHosts = lib.mkOption {
      type = types.lines;
      default = "";
      example = "192.168.0.1 lanlocalhost";
      description = ''
        Additional verbatim entries to be appended to <filename>/etc/hosts</filename>.
      '';
    };

    networking.nameservers = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["208.67.222.222" "208.67.220.220"];
      description = ''
        The list of nameservers.  It can be left empty if it is auto-detected through DHCP.
      '';
    };

    networking.search = mkOption {
      default = [];
      example = [ "example.com" "local.domain" ];
      type = types.listOf types.str;
      description = ''
        The list of search paths used when resolving domain names.
      '';
    };

    networking.domain = mkOption {
      default = null;
      example = "home";
      type = types.nullOr types.str;
      description = ''
        The domain.  It can be left empty if it is auto-detected through DHCP.
      '';
    };
  };

  ###### implementation

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
      run = with config.networking; ''
        ensureServiceStarted eudev-trigger

        ${config.networking.preConfig}

        ip6tables -t raw -I PREROUTING -m rpfilter --invert -j DROP

        ${lib.optionalString static.enable ''
        ip addr add ${static.ip} dev ${static.interface}
        ip link set ${static.interface} up
        ip route add ${static.route} dev ${static.interface}
        ip route add default via ${static.gw} dev ${static.interface}
        ''}

        ${lib.optionalString config.networking.dhcp ''
        ${pkgs.dhcpcd}/sbin/dhcpcd
        ''}

        ${lib.optionalString config.networking.lxcbr ''
        brctl addbr lxcbr0
        brctl setfd lxcbr0 0
        ip addr add 192.168.1.1 dev lxcbr0
        ip link set promisc on lxcbr0
        ip link set lxcbr0 up
        ip route add 192.168.1.0/24 dev lxcbr0
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
        ''}

        ${config.networking.custom}
      '';
      oneShot = true;
      onChange = "ignore";
    };
  };
}
