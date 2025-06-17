{ config, lib, pkgs, utils, ... }:
let
  inherit (lib) concatMapStringsSep mkOption optionalString splitString types;

  cfg = config.services.rsyslogd;

  forwardHostsRules = concatMapStringsSep "\n" (hostPort:
    let parts = splitString ":" hostPort;
        host  = builtins.elemAt parts 0;
        port  = builtins.elemAt parts 1;
    in ''
      action(
        name="fwd_${host}_${port}"
        type="omfwd"
        target="${host}"
        port="${port}"
        protocol="tcp"
        template="RSYSLOG_SyslogProtocol23Format"

        queue.type="linkedlist"
        queue.filename="fwdRule1"
        queue.maxdiskspace="1g"
        action.resumeRetryCount="-1"
      )
    '') cfg.forward;

  rsyslogConfig = pkgs.writeText "rsyslog.conf" ''
    global(
      workDirectory="/var/spool/rsyslog"
      ${optionalString (!isNull cfg.hostName) ''localHostname="${cfg.hostName}"''}
    )

    module(load="imuxsock")
    module(load="imklog")
    module(load="imudp")

    input(type="imudp" address="127.0.0.1" port="514")

    # "local1" is used for dhcpd messages
    if ($syslogfacility-text == "local1") then {
      action(type="omfile" file="/var/log/dhcpd")
      stop
    }

    # mail.*
    if ($syslogfacility-text == "mail") then {
      action(type="omfile" file="/var/log/mail")
      stop
    }

    # local2.*
    if ($syslogfacility-text == "local2") then {
      action(type="omfile" file="/var/log/osctld")
      stop
    }

    # local3.*
    if ($syslogfacility-text == "local3") then {
      action(type="omfile" file="/var/log/nodectld")
      stop
    }

    # default: everything else, except mail & local1 → /var/log/messages
    if not (
        $syslogfacility-text == "mail"
      or $syslogfacility-text == "local1"
    ) then {
      action(type="omfile" file="/var/log/messages")
    }

    ${optionalString (cfg.forward != []) forwardHostsRules}

    ${cfg.extraConfig}
  '';

  pidFile = "/run/rsyslog.pid";
in
{
  ###### interface

  options = {
    services = {
      rsyslogd = {
        hostName = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Optional hostname";
        };

        forward = mkOption {
          type = types.listOf types.str;
          description = "Forward logs over TCP to a set of hosts";
          example = [ "10.0.0.1:11514" ];
          default = [];
        };

        extraConfig = mkOption {
          type = types.str;
          default = "";
          example = "news.* -/var/log/news";
          description = "Additional text to append to syslog.conf";
        };
      };
    };
  };

  ###### implementation

  config = {
    runit.services.rsyslog = {
      run = ''
        mkdir -p /var/spool/rsyslog
        exec ${pkgs.rsyslog-light}/sbin/rsyslogd -f ${rsyslogConfig} -n -i ${pidFile}
      '';
      runlevels = [ "rescue" "default" ];
    };

    services.logrotate.logFiles = [
      {
        files = [
          "/var/log/messages"
          "/var/log/osctld"
          "/var/log/nodectld"
        ];
        config = ''
          daily
          rotate 1
          nodateext
          copytruncate
          notifempty
          nocompress
          maxsize 100M
          postrotate
            kill -HUP `cat /var/run/rsyslog.pid`
          endscript
        '';
      }
    ];
  };
}
