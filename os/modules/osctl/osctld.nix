{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  path = with pkgs; [
    apparmor-parser
    coreutils
    iproute
    glibc.bin
    gzip
    lxc
    nettools
    gnutar
    openssh
    pty-wrapper
    runit
    shadow
    utillinux
    zfs
  ];
  pathJoined = concatMapStringsSep ":" (s: "${s}/bin") path;
  apparmorPaths = [ pkgs.apparmor-profiles ] ++ config.security.apparmor.packages;
  apparmorPathsJoined = concatMapStringsSep ":" (s: "${s}/etc/apparmor.d") apparmorPaths;
in
{
  ###### interface

  options = {
  };

  ###### implementation

  config = {
    runit.services.osctld = {
      run = ''
        export PATH="${config.security.wrapperDir}:${pathJoined}"
        export OSCTLD_APPARMOR_PATHS="${apparmorPathsJoined}"

        ${optionalString config.system.boot.restrict-proc-sysfs.enable ''
        waitForService restrict-proc-sysfs
        ''}

        exec 2>&1
        exec ${pkgs.osctld}/bin/osctld --log syslog --log-facility local2
      '';
      killMode = "process";
    };
  };
}
