{ lib, ... }:

with lib;

{
  options = {
    boot.initrd.systemd = {
      enable = mkOption { type = types.bool; default = false; readOnly = true; };
      contents = mkOption { type = types.unspecified; };
      managerEnvironment = mkOption { type = types.unspecified; };
      services = mkOption { type = types.unspecified; };
      storePaths = mkOption { type = types.unspecified; };
      network.enable = mkOption { type = types.bool; default = false; readOnly = true; };
    };
    services = {
      cgmanager = mkOption { type = types.unspecified; };
      fprintd = mkOption { type = types.unspecified; };
      geoclue2 = mkOption { type = types.unspecified; };
      sssd = mkOption { type = types.unspecified; };
      homed.enable = mkOption { type = types.bool; default = false; };
      nscd = mkOption { type = types.unspecified; };
      avahi = mkOption { type = types.unspecified; };
      samba = mkOption { type = types.unspecified; };
      xserver = mkOption { type = types.unspecified; };
    };
    networking.enableIPv6 = mkOption { default = true; };
    networking.hostId = mkOption { type = types.unspecified; };
    networking.networkmanager = mkOption { type = types.unspecified; };
    krb5 = mkOption { type = types.unspecified; };
    security.virtualisation = mkOption { type = types.unspecified; };
    security.pam.oath.enable = mkOption { type = types.unspecified; };
    security.pam.usb.enable = mkOption { type = types.unspecified; };
    security.pam.mount.enable = mkOption { type = types.unspecified; };

    systemd = {
      globalEnvironment = mkOption { type = types.unspecified; };
      package = mkOption { type = types.unspecified; default = "/not-on-vpsadminos"; };
      packages = mkOption { type = types.unspecified; };
      services = mkOption {
        type = types.attrsOf types.unspecified;
      };
      sockets = mkOption { type = types.unspecified; };
      targets = mkOption { type = types.unspecified; };
      tmpfiles = mkOption { type = types.unspecified; };
      user = mkOption { type = types.unspecified; };
    };
  };
  config = {
    services = {
      avahi = { enable = false; nssmdns = false; };
      cgmanager = { enable = false; };
      sssd = { enable = false; };
      nscd = { enable = false; };
      fprintd = { enable = false; };
      samba = { enable = false; syncPasswordsByPam = false; nsswins = false; };
      xserver = { enable = false; };
    };
    krb5 = { enable = false; };
    security.pam.oath.enable = false;
    security.pam.usb.enable = false;
    security.pam.mount.enable = false;
    security.pam.services.su.forwardXAuth = mkForce false;
    security.pam.services.sshd.startSession = mkForce false;
    security.pam.services.login.startSession = mkForce false;
  };
}
