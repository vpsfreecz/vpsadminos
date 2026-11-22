{ config, lib, ... }:

with lib;

{
  options = {
    boot.initrd.systemd = {
      enable = mkOption {
        type = types.bool;
        default = false;
        readOnly = true;
      };
      contents = mkOption { type = types.unspecified; };
      managerEnvironment = mkOption { type = types.unspecified; };
      mounts = mkOption { type = types.unspecified; };
      services = mkOption { type = types.unspecified; };
      storePaths = mkOption { type = types.unspecified; };
      network.enable = mkOption {
        type = types.bool;
        default = false;
        readOnly = true;
      };
      additionalUpstreamUnits = mkOption { type = types.unspecified; };
    };
    boot.isNspawnContainer = mkOption {
      type = types.bool;
      default = false;
    };
    programs = {
      i3lock.enable = mkOption {
        type = types.bool;
        default = false;
      };
    };
    services = {
      cgmanager = mkOption { type = types.unspecified; };
      displayManager = mkOption { type = types.unspecified; };
      firewalld.enable = mkOption {
        type = types.bool;
        default = false;
      };
      fprintd = mkOption { type = types.unspecified; };
      geoclue2 = mkOption { type = types.unspecified; };
      intune = mkOption { type = types.unspecified; };
      sssd = mkOption { type = types.unspecified; };
      homed.enable = mkOption {
        type = types.bool;
        default = false;
      };
      howdy.enable = mkOption {
        type = types.bool;
        default = false;
      };
      nscd = mkOption { type = types.unspecified; };
      avahi = mkOption { type = types.unspecified; };
      samba = mkOption { type = types.unspecified; };
      xserver = mkOption { type = types.unspecified; };
      kanidm.enablePam = mkOption {
        type = types.bool;
        default = false;
      };
      kanidm.unix.enable = mkOption {
        type = types.bool;
        default = false;
      };
      userborn.enable = mkOption {
        type = types.bool;
        default = false;
      };
      xscreensaver.enable = mkOption {
        type = types.bool;
        default = false;
      };
    };
    networking.enableIPv6 = mkOption { default = true; };
    networking.hostId = mkOption { type = types.unspecified; };
    networking.networkmanager = mkOption { type = types.unspecified; };
    security.krb5 = mkOption { type = types.unspecified; };
    security.virtualisation = mkOption { type = types.unspecified; };
    security.pam.oath.enable = mkOption { type = types.unspecified; };
    security.pam.usb.enable = mkOption { type = types.unspecified; };
    security.pam.mount.enable = mkOption { type = types.unspecified; };

    # The upstream nix-channel module contributes a warning about stale channel
    # paths when channels are disabled. It does not block a switch, and the
    # runit activator does not run NixOS pre-switch scripts.
    system.preSwitchChecks.no-nix-channel = mkOption {
      type = types.str;
      internal = true;
    };

    systemd = {
      generatorEnvironment = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
      generatorPath = mkOption {
        type = types.listOf types.package;
        default = [ ];
      };
      globalEnvironment = mkOption { type = types.unspecified; };
      mounts = mkOption { type = types.unspecified; };
      package = mkOption {
        type = types.unspecified;
        default = "/not-on-vpsadminos";
      };
      packages = mkOption { type = types.unspecified; };
      services = mkOption {
        type = types.attrsOf types.unspecified;
      };
      sockets = mkOption { type = types.unspecified; };
      sysusers = mkOption { type = types.unspecified; };
      targets = mkOption { type = types.unspecified; };
      tmpfiles = mkOption { type = types.unspecified; };
      user = mkOption { type = types.unspecified; };
      additionalUpstreamUnits = mkOption { type = types.unspecified; };
      additionalUpstreamSystemUnits = mkOption { type = types.unspecified; };
    };
  };
  config = {
    # The upstream users module validates initrd IDs even for the non-systemd
    # initrd. Supply the missing GID to that check, not to the host groups.
    boot.initrd.systemd.groups.systemd-journal.gid = mkIf config.boot.initrd.enable (
      mkDefault config.ids.gids.systemd-journal
    );

    services = {
      avahi = {
        enable = false;
        nssmdns = false;
      };
      cgmanager.enable = false;
      displayManager.enable = false;
      intune.enable = false;
      sssd.enable = false;
      nscd.enable = false;
      fprintd = {
        enable = false;
        enablePam = false;
      };
      samba = {
        enable = false;
        syncPasswordsByPam = false;
        nsswins = false;
      };
      xserver.enable = false;
    };
    security.krb5.enable = false;
    security.pam.oath.enable = false;
    security.pam.usb.enable = false;
    security.pam.mount.enable = false;
    security.pam.services.su.forwardXAuth = mkForce false;
    security.pam.services.sshd.startSession = mkForce false;
    security.pam.services.login.startSession = mkForce false;
    systemd.sysusers.enable = false;
  };
}
