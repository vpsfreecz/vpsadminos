{ config, pkgs, ... }:

# Production configuration
# no bridge, NAT, dhcpd

{
  imports = [ ./conf_common.nix ];
  networking.hostName = "vpsadminos-prod";
  networking.dhcp = true;

  vpsadminos.nix = false;
  environment.systemPackages = with pkgs; [
    nvi
    ipmicfg
  ];

  # to be able to include ipmicfg
  nixpkgs.config.allowUnfree = true;
}
