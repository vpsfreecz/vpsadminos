{ lib, ... }:

with lib;

{
  options = {
    services = {
      cgmanager = mkOption { };
      fprintd = mkOption { };
      sssd = mkOption { };
      nscd = mkOption { };
      avahi = mkOption { };
      samba = mkOption { };
      xserver = mkOption { };
    };
    meta = {
      mainainers = mkOption { };
    };
    networking.firewall = mkOption { };
    networking.enableIPv6 = mkOption { default = true; };
    programs.ssh.package = mkOption { };
    programs.ssh.setXAuthLocation = mkOption { default = false; };
    krb5 = mkOption { };
    security.wrappers = mkOption { };
    security.pam.oath.enable = mkOption { };
    security.pam.usb.enable = mkOption { };
    security.pam.mount.enable = mkOption { };

    systemd.services = mkOption { };
  };
  config = {
    services = {
      avahi = { enable = false; nssmdns = false; };
      cgmanager = { enable = false; };
      sssd = { enable = false; };
      nscd = { enable = false; };
      fprintd = { enable = false; };
      samba = { enable = false; syncPasswordsByPam = false; nsswins = false; };
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
