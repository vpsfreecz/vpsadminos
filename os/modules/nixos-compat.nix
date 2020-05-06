{ lib, ... }:

with lib;

{
  options = {
    services = {
      cgmanager = mkOption { };
      fprintd = mkOption { };
      geoclue2 = mkOption { };
      sssd = mkOption { };
      nscd = mkOption { };
      avahi = mkOption { };
      samba = mkOption { };
      xserver = mkOption { };
    };
    meta = {
      mainainers = mkOption { };
    };
    networking.enableIPv6 = mkOption { default = true; };
    programs.ssh.package = mkOption { };
    programs.ssh.setXAuthLocation = mkOption { default = false; };
    krb5 = mkOption { };
    security.pam.oath.enable = mkOption { };
    security.pam.usb.enable = mkOption { };
    security.pam.mount.enable = mkOption { };

    systemd = {
      globalEnvironment = mkOption {};
      packages = mkOption {};
      services = mkOption {
        type = types.attrsOf types.unspecified;
      };
      sockets = mkOption {};
      targets = mkOption {};
      tmpfiles = mkOption {};
      user = mkOption {};
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
