{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.dbus;

  configDir = pkgs.makeDBusConf.override {
    dbus = cfg.dbusPackage;
    suidHelper = "${config.security.wrapperDir}/dbus-daemon-launch-helper";
    serviceDirectories = cfg.packages;
  };
in
{
  options = {
    services.dbus = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        internal = true;
        description = ''
          Whether to start the D-Bus message bus daemon, which is
          required by many other system services and applications.
        '';
      };

      dbusPackage = lib.mkPackageOption pkgs "dbus" { };

      packages = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = ''
          Packages whose D-Bus configuration files should be included in
          the configuration of the D-Bus system-wide or session-wide
          message bus.  Specifically, files in the following directories
          will be included into their respective DBus configuration paths:
          {file}`«pkg»/etc/dbus-1/system.d`
          {file}`«pkg»/share/dbus-1/system.d`
          {file}`«pkg»/share/dbus-1/system-services`
          {file}`«pkg»/etc/dbus-1/session.d`
          {file}`«pkg»/share/dbus-1/session.d`
          {file}`«pkg»/share/dbus-1/services`
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."dbus-1".source = configDir;

    environment.pathsToLink = [
      "/etc/dbus-1"
      "/share/dbus-1"
    ];

    users.users.messagebus = {
      uid = config.ids.uids.messagebus;
      description = "D-Bus system message bus daemon user";
      home = "/run/dbus";
      homeMode = "0755";
      group = "messagebus";
    };

    users.groups.messagebus.gid = config.ids.gids.messagebus;

    environment.systemPackages = [
      cfg.dbusPackage
    ];

    services.dbus.packages = [
      cfg.dbusPackage
      config.system.path
    ];

    runit.services.dbus = {
      run = ''
        if [ ! -d /run/dbus ] ; then
          install -m 755 \
                  -o ${toString config.users.users.messagebus.uid} \
                  -g ${toString config.users.groups.messagebus.gid} \
                  -d /run/dbus
        fi

        exec ${cfg.dbusPackage}/bin/dbus-daemon --system --nofork --nopidfile
      '';

      check = ''
        exec ${cfg.dbusPackage}/bin/dbus-send --system / org.freedesktop.DBus.Peer.Ping > /dev/null 2> /dev/null
      '';

      onChange = "ignore";

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
