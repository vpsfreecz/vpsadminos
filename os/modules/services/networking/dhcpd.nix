{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf;

  stateDir = "/var/lib/lxcbr-dnsmasq";

  bridge = "lxcbr0";

  user = "lxcbr-dnsmasq";

  dnsmasqConf = pkgs.writeText "lxcbr-dnsmasq.conf" ''
    interface=${bridge}
    listen-address=192.168.1.1
    bind-interfaces
    dhcp-option=3,192.168.1.1 # gateway
    dhcp-option=6,192.168.1.1 # dns servers
    dhcp-range=192.168.1.100,192.168.1.200,255.255.255.0,1h
    dhcp-leasefile=${stateDir}/dnsmasq.leases
    dhcp-authoritative
  '';
in {
  options = {
    networking.dhcpd = mkEnableOption "Enable DHCP server for containers using ${bridge}";
  };

  config = mkIf config.networking.dhcpd {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      description = "Dnsmasq daemon for lxcbr";
    };
    users.groups.${user} = {};

    runit.services.lxcbr-dnsmasq = {
      run = ''
        until ip link show dev ${bridge} >/dev/null 2>&1 ; do
          echo "lxcbr-dnsmasq waiting for interface ${bridge}"
          sleep 1
        done

        mkdir -p "${stateDir}"
        touch ${stateDir}/dnsmasq.leases
        chown -R ${user} ${stateDir}

        exec ${pkgs.dnsmasq}/bin/dnsmasq -k --user=${user} -C ${dnsmasqConf}
      '';
    };

    # See https://github.com/NixOS/nixpkgs/issues/263359
    networking.firewall.interfaces.${bridge} = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 67 ];
    };
  };
}
