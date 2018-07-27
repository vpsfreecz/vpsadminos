{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

{
  ###### interface

  options = {
    networking.dhcpd = mkEnableOption "Enable dhcpd for lxc containers";
  };

  ###### implementation

  config = mkMerge [
    (mkIf (config.networking.dhcpd) {
      runit.services.dhcpd.run = ''
        sv check networking >/dev/null || exit 1
        mkdir -p /var/lib/dhcp
        touch /var/lib/dhcp/dhcpd4.leases
        exec ${pkgs.dhcp}/sbin/dhcpd -4 -f \
          -pf /run/dhcpd4.pid \
          -cf /etc/dhcpd/dhcpd4.conf \
          -lf /var/lib/dhcp/dhcpd4.leases \
          lxcbr0
      '';

      environment.etc."dhcpd/dhcpd4.conf".text = ''
        authoritative;
        option routers 192.168.1.1;
        option domain-name-servers 208.67.222.222, 208.67.220.220;
        option subnet-mask 255.255.255.0;
        option broadcast-address 192.168.1.255;
        subnet 192.168.1.0 netmask 255.255.255.0 {
          range 192.168.1.100 192.168.1.200;
        }
      '';
    })
  ];
}
