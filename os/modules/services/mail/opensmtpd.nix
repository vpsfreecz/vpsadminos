{ config, lib, pkgs, ... }:

with lib;

let

  cfg = config.services.opensmtpd;
  conf = pkgs.writeText "smtpd.conf" cfg.serverConfiguration;
  args = concatStringsSep " " cfg.extraServerArgs;

  sendmail = pkgs.runCommand "opensmtpd-sendmail" { preferLocalBuild = true; } ''
    mkdir -p $out/bin
    ln -s ${cfg.package}/sbin/smtpctl $out/bin/sendmail
  '';

in {

  ###### interface

  options = {

    services.opensmtpd = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = lib.mdDoc "Whether to enable the OpenSMTPD server.";
      };

      package = mkOption {
        type = types.package;
        default = pkgs.opensmtpd;
        defaultText = literalExpression "pkgs.opensmtpd";
        description = lib.mdDoc "The OpenSMTPD package to use.";
      };

      setSendmail = mkOption {
        type = types.bool;
        default = true;
        description = lib.mdDoc "Whether to set the system sendmail to OpenSMTPD's.";
      };

      extraServerArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "-v" "-P mta" ];
        description = lib.mdDoc ''
          Extra command line arguments provided when the smtpd process
          is started.
        '';
      };

      serverConfiguration = mkOption {
        type = types.lines;
        example = ''
          listen on lo
          accept for any deliver to lmtp localhost:24
        '';
        description = lib.mdDoc ''
          The contents of the smtpd.conf configuration file. See the
          OpenSMTPD documentation for syntax information.
        '';
      };

      procPackages = mkOption {
        type = types.listOf types.package;
        default = [];
        description = lib.mdDoc ''
          Packages to search for filters, tables, queues, and schedulers.

          Add OpenSMTPD-extras here if you want to use the filters, etc. from
          that package.
        '';
      };
    };
  };


  ###### implementation

  config = mkIf cfg.enable rec {
    users.groups = {
      smtpd.gid = config.ids.gids.smtpd;
      smtpq.gid = config.ids.gids.smtpq;
    };

    users.users = {
      smtpd = {
        description = "OpenSMTPD process user";
        uid = config.ids.uids.smtpd;
        group = "smtpd";
      };
      smtpq = {
        description = "OpenSMTPD queue user";
        uid = config.ids.uids.smtpq;
        group = "smtpq";
      };
    };

    security.wrappers.smtpctl = {
      owner = "root";
      group = "smtpq";
      setuid = false;
      setgid = true;
      source = "${cfg.package}/bin/smtpctl";
    };

    services.mail.sendmailSetuidWrapper = mkIf cfg.setSendmail
      (security.wrappers.smtpctl // { program = "sendmail"; });

    runit.services.opensmtpd = let
      procEnv = pkgs.buildEnv {
        name = "opensmtpd-procs";
        paths = [ cfg.package ] ++ cfg.procPackages;
        pathsToLink = [ "/libexec/opensmtpd" ];
      };
    in {
      run = ''
        export OPENSMTPD_PROC_PATH="${procEnv}/libexec/opensmtpd"

        mkdir -p /var/spool/smtpd
        chmod 711 /var/spool/smtpd

        mkdir -p /var/spool/smtpd/offline
        chown root.smtpq /var/spool/smtpd/offline
        chmod 770 /var/spool/smtpd/offline

        mkdir -p /var/spool/smtpd/purge
        chown smtpq.root /var/spool/smtpd/purge
        chmod 700 /var/spool/smtpd/purge

        exec ${cfg.package}/sbin/smtpd -d -f ${conf} ${args}
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
