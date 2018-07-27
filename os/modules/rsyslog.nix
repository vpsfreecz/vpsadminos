{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  syslog_config = pkgs.writeText "syslog.conf" ''
    $ModLoad imuxsock
    $WorkDirectory /var/spool/rsyslog

    # "local1" is used for dhcpd messages.
    local1.*                     -/var/log/dhcpd

    mail.*                       -/var/log/mail

    local2.*                     -/var/log/osctld
    local3.*                     -/var/log/nodectld

    *.=warning;*.=err            -/var/log/warn
    *.crit                        /var/log/warn

    *.*;mail.none;local1.none    -/var/log/messages
  '';
in
{
  ###### interface

  options = {
  };

  ###### implementation

  config = {
    runit.services.rsyslog.run = ''
      mkdir -p /var/spool/rsyslog
      exec ${pkgs.rsyslog-light}/sbin/rsyslogd -f ${syslog_config} -n -i /run/rsyslog.pid
    '';
  };
}
