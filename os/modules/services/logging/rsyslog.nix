{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  cfg = config.services.rsyslogd;
  forwardHosts = concatMapStringsSep "\n" (hostPort: "*.* @@${hostPort};RSYSLOG_SyslogProtocol23Format") cfg.forward;
  syslog_config = pkgs.writeText "syslog.conf" ''
    ${optionalString (!isNull cfg.hostName) ''
    $LocalHostName ${cfg.hostName}
    ''}

    $ModLoad imuxsock
    $ModLoad imklog
    $ModLoad imudp
    $WorkDirectory /var/spool/rsyslog

    $UDPServerAddress 127.0.0.1
    $UDPServerRun 514

    # "local1" is used for dhcpd messages.
    local1.*                     -/var/log/dhcpd

    mail.*                       -/var/log/mail

    local2.*                     -/var/log/osctld
    local3.*                     -/var/log/nodectld

    *.*;mail.none;local1.none    -/var/log/messages

    ${ optionalString (cfg.forward != []) ''
    $ActionQueueFileName fwdRule1 # unique name prefix for spool files
    $ActionQueueMaxDiskSpace 1g   # 1gb space limit (use as much as possible)
    $ActionQueueType LinkedList   # run asynchronously
    $ActionResumeRetryCount -1    # infinite retries if host is down

    ''}
    ${forwardHosts}

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
        exec ${pkgs.rsyslog-light}/sbin/rsyslogd -f ${syslog_config} -n -i ${pidFile}
      '';
      runlevels = [ "rescue" "default" ];
    };

    services.logrotate.logFiles = [
      {
        files = [
          "/var/log/messages"
          "/var/log/warn"
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
