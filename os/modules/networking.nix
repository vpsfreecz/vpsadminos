{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

{
  ###### interface

  options = {
  };

  ###### implementation

  config = {
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
