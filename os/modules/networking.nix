{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

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
  };

  ###### implementation

  config = {
    environment.etc = {
      # /etc/hosts: Hostname-to-IP mappings.
      "hosts".text =
        let cfg = config.networking;
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
    };

    runit.services = {
      networking.run = with config.networking; ''
        sv check eudev-trigger >/dev/null || exit 1

        ${config.networking.preConfig}

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

        touch /run/net-done
        exec sleep inf
      '';

      networking.check = ''
        test -f /run/net-done
      '';
    };
  };
}
