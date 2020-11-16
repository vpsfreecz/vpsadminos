{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.system.boot.restrict-proc-sysfs;

  restrictProcSysfs = pkgs.callPackage ./restrict-dirs.nix {};

  configFile = pkgs.writeText "restrict-proc-sysfs-config.txt" cfg.config;
in {
  options = {
    system.boot.restrict-proc-sysfs = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Restrict access to proc, sysfs and any other filesystem contents
        '';
      };

      config = mkOption {
        type = types.lines;
        default = builtins.readFile ./config.txt;
        description = ''
          Config passed to ./restrict-dirs.rb

          Each line represents a rule for a path. The first word is a command,
          the second word is the path. The command can be one of: restrict, skip
          and grant. Empty lines and lines beginning with a hash are ignored.

          restrict is used to deny access from containers to the path, skip does
          not change the access mode and grant will give read-write access to
          containers and all their users, even unprivileged ones.

          The path can contain patterns, which are expanded. Rules are evaluated
          from the top. There can be more than one rule for one path, the last
          rule will be used. This makes it possible to e.g. use wildcards with
          exceptions:

          restrict /sys/class/*
          skip /sys/class/net

          The rules above will restrict access to the contents of /sys/class,
          except for directory /sys/class/net.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    runit.services.restrict-proc-sysfs = {
      run = ''
        sleep 10
        ${restrictProcSysfs} ${configFile}
      '';
      oneShot = true;
      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
