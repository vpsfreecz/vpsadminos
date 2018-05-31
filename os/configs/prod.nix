{ config, pkgs, ... }:

# Production configuration
# no bridge, NAT, dhcpd

{
  imports = [ ./common.nix ];
  networking.hostName = "vpsadminos-prod";
  networking.dhcp = true;

  networking.bird = {
    enable = true;
    routerId = "1.2.3.4";
    protocol.bgp = {
      bgp1 = rec {
        as = 65000;
        nextHopSelf = true;
        neighbor = { "172.17.4.1" = as; };
        extraConfig = ''
          export all;
          import all;
        '';
      };
    };

    protocol.kernel.extraConfig = ''
      export all;
      import all;
      import filter {
        if net.len > 25 then accept;
        reject;
      };
    '';
  };


  boot.kernelModules = [ "ipmi_si" "ipmi_devintf" ];
  boot.zfs.pool.layout = "mirror sda sdb";

  vpsadminos.nix = true;
  environment.systemPackages = with pkgs; [
    config.boot.kernelPackages.bcc
    dstat
    dmidecode
    ipmicfg
    lm_sensors
    pciutils
    smartmontools
    usbutils
  ];

  # to be able to include ipmicfg
  nixpkgs.config.allowUnfree = true;
}
