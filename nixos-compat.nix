{ lib, ... }:

with lib;

{
  options = {
    services = {
      cgmanager = mkOption { };
      fprintd = mkOption { };
      sssd = mkOption { };
      nscd = mkOption { };
      samba = mkOption { };
      zfs = mkOption { };
    };
    meta = {
      mainainers = mkOption { };
    };
    networking.firewall = mkOption { };
    programs.ssh.package = mkOption { };
    krb5 = mkOption { };
    security.wrappers = mkOption { };
    security.pam.oath.enable = mkOption { };
    security.pam.usb.enable = mkOption { };
    security.pam.mount.enable = mkOption { };

    systemd.services = mkOption { };
  };
  config = {
    services = {
      cgmanager = { enable = false; };
      sssd = { enable = false; };
      nscd = { enable = false; };
      fprintd = { enable = false; };
      samba = { enable = false; syncPasswordsByPam = false; };
      zfs = {};
    };
    krb5 = { enable = false; }; 
    security.pam.oath.enable = false;
    security.pam.usb.enable = false;
    security.pam.mount.enable = false;
  };
}
